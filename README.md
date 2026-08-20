# Mentat

**The OCaml coding agent.**

Mentat is a coding agent specialized for OCaml. Instead of treating your code
as plain text, it works with the language's semantics and tooling: it watches
Dune diagnostics while it edits, navigates code through Merlin, edits syntax
trees rather than strings when that is safer, picks up `CR` review comments
you drop in the source, and ships with built-in skills for OCaml development
workflows. The result is an agent that converges faster, produces changes
that compile, and needs less babysitting than a generic agent pointed at an
OCaml codebase.

> **Status: experimental.** This is a first public release. The core loop
> works and we use Mentat on Mentat daily, but interfaces, configuration, and
> session formats will change without notice. Expect rough edges and please
> report them.

## Why an OCaml agent?

Mentat is opinionated by design. The premise is that a coding agent
specialized to one language and its ecosystem can be dramatically more
productive than a generic agent: it knows the build system, the tooling, the
idioms, and the failure modes, and it gets language-level feedback that plain
text tools cannot provide.

But specialization is only half of the story. Our goal is to build the safest
and most productive coding agent there is, and OCaml is the strongest target
for that goal:

- **The language is built for machine-checkable correctness.** A sound type
  system, expressive static types, and explicit module interfaces mean the
  agent gets strong, immediate, trustworthy feedback on every change — far
  more signal than "it seems to run".
- **The ecosystem has a culture of correctness.** Typed build rules,
  property-based testing, and documentation-as-contract give the agent rich
  verification loops to work inside.
- **It is the strongest path to a formal-verification-first agent.** Through
  the Rocq ecosystem and its deep integration with OCaml, we can push the
  agent beyond "compiles and passes tests" toward producing formally verified
  code by default where it matters.

## Where it differs from a generic agent

### The build loop is the agent loop

Mentat connects to your running Dune instance over RPC and pushes compiler
errors and warnings into the agent loop as they happen. This is not an
after-the-edit check on the file the agent just touched: the host watches the
whole workspace — builds, diagnostics, file changes, review comments — and
injects whatever changed before every model request. The agent sees the
fallout of its own edit before taking the next step, and a clean diagnostic
set — not "the edit applied" — is its baseline for calling a change done.

### OCaml-native tools and skills

Alongside the usual file, search, and shell tools, the model gets
OCaml-native tools:

- `ocaml_dune_describe` — a semantic description of the project from Dune
  metadata: libraries, executables, dependencies, tests.
- `ocaml_docs` — the API surface (signatures and documentation) of OCaml code
  by name or path, across your workspace libraries and locked dependencies,
  instead of reading whole files.
- `ocaml_find_definitions` / `ocaml_find_references` / `ocaml_type_at` —
  identity-based navigation and type inspection through Merlin, not textual
  grep.
- `ocaml_ast_edit` / `ocaml_replace_expressions` / `ocaml_rename` — syntax-aware
  edits addressed by compiler AST location or identity; replacement fragments
  are parsed before the file is written, so a fragment that does not parse is
  rejected instead of corrupting the file.
- `ocaml_search_expressions` — structural search over syntax trees rather than
  text.
- `ocaml_eval` — evaluate toplevel phrases in the project's context.

Compiler and Dune diagnostics are not a tool the model has to pull: the
workspace watcher pushes the current error set into the loop as it changes.

Mentat also ships with opinionated skills for OCaml work — testing,
documentation, module and library design, FFI, performance, benchmarking,
debugging, project setup, and code tidying — so the agent follows good
ecosystem practice with zero configuration. In a trusted workspace,
project-local skills in `.mentat/skills` (and existing `.claude/skills` or
`.agents/skills`) are picked up automatically.

For the language-agnostic half of the job, Mentat adopts the editing and
context optimizations pioneered by agents like Dirac: anchored line edits that
survive whitespace and repetition, exact-string edits, atomic multi-file
patches, and host-side suppression of redundant reads.

### Code review lives in the source

Mentat speaks the `CR` review-comment convention. Drop a comment in the code —

```ocaml
(* CR mentat: this validation belongs in Lpath, not here *)
```

— and the workspace watcher delivers it to the agent live, mid-session:
feedback anchored to the exact code it is about, with no need to interrupt
the agent or rebuild context in a prompt. The agent addresses the comment and
resolves it as `XCR`; `CR-soon` defers work without losing it.

### Safe by default

Three independent boundaries, each one inspectable from the command line:

- **Permission rules** decide what the agent may do without asking. They are
  durable and readable: `mentat permission list`.
- **The command sandbox** decides what a command can reach — `read-only`,
  `workspace-write`, or `danger-full-access`. It fails closed when the
  platform cannot enforce it, and `mentat sandbox status` reports which
  backend is active and what it permits.
- **Workspace trust** decides whether a project's own configuration,
  instructions, and skills take effect at all. An unfamiliar workspace asks
  before activation; headless runs proceed with project customization off.

Whatever gets through, you can undo. Every session records the files it
touched, so `mentat session diff` shows what the agent changed and
`mentat session revert` takes it back, turn by turn.

[Security](doc/manual/security.md) covers all three in full, including how to
opt a local model into read-anywhere, write-confined execution.

## Install

Prebuilt binaries are available for macOS (Apple Silicon and Intel) and
Linux (x64 and arm64, fully static):

```sh
curl -fsSL https://raw.githubusercontent.com/invariant-hq/mentat/main/scripts/install.sh | sh
```

The installer verifies the download against the release checksums and
installs to `~/.local/bin` (override with `MENTAT_INSTALL_DIR`; pin a
version with `MENTAT_VERSION=X.Y.Z`). If that directory is not already on
`PATH`, it adds it to the startup file for the detected shell. To prevent shell
startup-file edits:

```sh
curl -fsSL https://raw.githubusercontent.com/invariant-hq/mentat/main/scripts/install.sh | \
  sh -s -- --no-modify-path
```

Or with Homebrew:

```sh
brew install invariant-hq/tap/mentat
```

On Windows, use WSL2 and the Linux binary; WSL1 cannot enforce the default
sandbox.

Mentat relies on a few host tools that are not part of the release archive:

| Use | Host prerequisite |
| --- | --- |
| Default enforced sandbox on Linux | A working Bubblewrap executable at exactly `/usr/bin/bwrap`; a copy elsewhere on `PATH` is not used. WSL1 cannot provide this backend. |
| Source search | `rg` (ripgrep) on `PATH`; without it, `search_text` reports that it is unavailable. |
| Managed `local` provider | `llama-server` on `PATH`, or an explicit `MENTAT_LOCAL_SERVER_BINARY`. |
| Build from source | Git, Dune 3.22+, a native C build toolchain, `pkg-config` or compatible `pkgconf`, and GMP development headers/libraries. zstd is optional unless enabled by the selected OCaml toolchain. |

Prebuilt releases carry their native-library linkage; source-build requirements
apply only to source builds. See
[Installation](doc/manual/installation.md) for the complete matrix and PATH
behavior.

### Building from source

Mentat uses Dune package management — you need a recent Dune (3.22+), and
`dune pkg lock` provisions the OCaml compiler (5.5+) and every OCaml
dependency. System libraries are not provisioned; `dune show depexts` prints
the ones your own package manager has to supply.

```sh
git clone https://github.com/invariant-hq/mentat.git
cd mentat
dune pkg lock
dune show depexts   # system packages to install before building
dune build
```

Run it from the checkout with `dune exec mentat --`, or install it on your
`PATH` with `dune install --prefix ~/.local`.

## Getting started

Before selecting a hosted model, read
[Data leaving your machine](doc/manual/security.md#data-leaving-your-machine).
Model requests can contain prompts, instructions, loaded skills, source and tool
output, and images. A fresh untitled session also makes a separate request with
its first prompt to the configured small model for auto-titling.

Authenticate with a provider. OpenAI supports OAuth or an API key; Anthropic,
Google, and OpenCode Go use API keys:

```sh
mentat auth login anthropic
mentat auth status
```

Then start the interactive agent in your project:

```sh
cd ~/my-project
mentat
```

The [getting-started walkthrough](doc/manual/getting-started.md) covers a
first change end to end on a throwaway project, including how to undo it.

## Usage

Bare `mentat` opens the terminal UI; type `/` for the command palette
(`/model`, `/plan`, `/sessions`, ...). `mentat run` runs headless sessions
for scripts and CI:

```sh
mentat run "Add an .mli for lib/user.ml and fix the resulting errors"
mentat run resume --last "Now update the tests"
```

Headless runs are a product contract: `--json` emits a schema-versioned
JSONL event stream, and when a run blocks on a permission or a question,
Mentat exits with code 3 and prints the exact command to resume it, so
unattended runs stay scriptable.

Sessions are global durable data under your data home
(`~/.local/share/mentat` by default), not project files; `mentat session diff`
and `mentat session revert` inspect and undo agent changes turn by turn. The
per-project `.mentat/` directory holds only shared config and skills. Configuration
is layered JSON; `mentat config show --origins` prints the effective
configuration and where each value came from.

The [manual](doc/manual/README.md) covers
[getting started](doc/manual/getting-started.md),
[installation](doc/manual/installation.md),
[security and outbound data](doc/manual/security.md#data-leaving-your-machine),
[interactive workflows](doc/manual/interactive.md),
[custom commands](doc/manual/custom-commands.md),
[providers](doc/manual/providers.md),
[instructions and skills](doc/manual/instructions-and-skills.md),
[configuration](doc/manual/configuration.md),
[sessions](doc/manual/sessions.md),
[headless runs, images, and output schemas](doc/manual/headless.md), and
[daemon and browser operation](doc/manual/daemon-and-web.md).

## Where we're going

Mentat is the agent layer of [Invariant](https://invarianthq.dev/)'s
stack, and it is heading in three directions:

1. **Local-first agents.** We think a coding agent should be like your build
   system: a developer tool you run locally, not a luxury product gated
   behind someone else's API. We are building
   [Raven](https://github.com/raven-ml/raven) as the foundational layer for
   model runtimes, and Mentat will provide local models built in, with no
   external integration required. A managed local model catalog already
   ships in the provider catalog as a first step.

2. **Push OCaml specialization as far as it goes.** Measure real-world
   productivity and code quality with **MentatBench**, our benchmark for
   agents on OCaml projects; grow an agent-friendly developer toolbox — the
   [windtrap](https://github.com/invariant-hq/windtrap) testing framework,
   the thumper benchmarking framework, a linter, and more; connect the agent
   to a living OCaml knowledge base, including ecosystem library knowledge;
   and encode development workflows — design review, documentation,
   benchmarking — as runtimes that guide and constrain the agent. A dedicated
   interface for `CR`-based review of agent changes is the next step there.

3. **Formal verification.** From the tooling to the model, we want Mentat to
   be the safest agent there is: when appropriate, it should default to
   producing formally verified code, building on Rocq and its OCaml
   integration.

## Contributing

Mentat is early and moving fast. The most useful contributions right now are
bug reports and real-world usage feedback —
[open an issue](https://github.com/invariant-hq/mentat/issues).
[CONTRIBUTING.md](CONTRIBUTING.md) explains what makes a report actionable,
how to build from source, and the conventions a patch is expected to follow.
For anything with a security impact, follow [SECURITY.md](SECURITY.md)
instead of opening an issue. The [documentation index](doc/README.md) links
the user manual, architecture, and maintainer references.

## License

Mentat is distributed under the ISC license. See [LICENSE](LICENSE).
