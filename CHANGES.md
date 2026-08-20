# 0.1.0 (unreleased)

The first public release of Mentat, a coding agent specialized for OCaml.

We have been using Mentat on Mentat daily for months; this release makes it
available for your own projects. It is experimental. The core loop works, but
interfaces, configuration, and session formats will change without notice, and
there are rough edges we would like to hear about.

## What it does

Mentat works with OCaml's semantics and tooling rather than treating source as
text. It connects to a running Dune instance over RPC and pushes compiler
errors and warnings into the agent loop as they happen, so the agent sees the
fallout of its own edit before taking the next step. A clean diagnostic set,
not a successful write, is its baseline for calling a change done.

Alongside the usual file, search, and shell tools, the model gets OCaml-native
ones: project description from Dune metadata (`ocaml_dune_describe`), API
surfaces instead of whole files (`ocaml_docs`), Merlin-backed navigation and
type inspection (`ocaml_find_definitions`, `ocaml_find_references`,
`ocaml_type_at`), edits addressed by compiler AST location or identity
(`ocaml_ast_edit`, `ocaml_replace_expressions`, `ocaml_rename`), structural
search (`ocaml_search_expressions`), and toplevel evaluation (`ocaml_eval`).
Replacement fragments are parsed before a file is written, so a fragment that
does not parse is rejected rather than corrupting the file.

It speaks the `CR` review-comment convention: a comment left in the source is
delivered to the agent live, mid-session, and resolved as `XCR`.

Built-in skills cover testing, documentation, module and library design, FFI,
performance, benchmarking, debugging, project setup, and code tidying. In a
trusted workspace, project-local skills in `.mentat/skills`, `.agents/skills`,
or `.claude/skills` are picked up automatically, and instruction files follow
the `AGENTS.md` ladder with `CLAUDE.md` compatibility.

## How you run it

Bare `mentat` opens the terminal interface. `mentat run` executes headless
turns for scripts and CI, and that surface is a product contract: a
schema-versioned JSONL event stream under `--json`, a stable exit-code
protocol, and exit code 3 with a printed `mentat run reply` continuation when
a run blocks on a review, question, or plan.

Sessions are durable and global. List, show, search, fork, rewind, archive,
compact, and export them; `mentat session diff` and `mentat session revert`
inspect and undo the agent's work turn by turn, from a mutation ledger rather
than from Git. Configuration is layered JSON, and `mentat config show
--origins` prints the effective values with the source of each one.

## Providers

OpenAI, Anthropic, and Google, through OAuth or an API key. Managed local
models and explicit `.gguf` paths through the `local` provider. Any OpenAI
chat-completions server — llama.cpp, vLLM, LM Studio, Ollama — through the
`ollama` provider. The OpenCode Go subscription gateway through the
`opencode-go` provider, with model metadata sourced from the gateway's serving
set. Provider declarations, accounts, and model selection are separate
concerns, so switching models does not disturb credentials.

## Safety

Three independent boundaries, each inspectable from the command line.
Permission rules are durable and readable with `mentat permission list`. The
command sandbox (`read-only`, `workspace-write`, `danger-full-access`,
`external-sandbox`) is enforced by macOS Seatbelt and Linux Bubblewrap, and
fails closed when the platform cannot enforce it. Workspace trust gates
whether a repository's own configuration, instructions, skills, and processes
activate at all.

## Platforms

Prebuilt binaries for macOS on Apple Silicon and Intel, and Linux on x64 and
arm64 as fully static musl builds. Install with `scripts/install.sh` or
Homebrew. Windows works through WSL2.

## Known limitations

- WSL1 cannot provide Bubblewrap and therefore cannot enforce the default
  sandbox.
- `search_text` needs `rg` (ripgrep) on `PATH`; without it the tool reports
  that it is unavailable.
- On Linux the sandbox uses `/usr/bin/bwrap` specifically. A copy elsewhere on
  `PATH` is not used.
- Permission rules are hand-authored JSON. `mentat config set` does not edit
  the structured rule list, and the interactive dialog does not offer family
  approvals.
- There is no dedicated interface for `CR`-based review of agent changes yet.
- Session formats are not stable across versions.
