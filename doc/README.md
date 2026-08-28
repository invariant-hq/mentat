# mentat documentation

The documentation is organized by audience and by source of truth. Start with
the user manual when operating the `mentat` binary and with the architecture
overview when changing how the libraries compose.

## User manual

- [Getting started](manual/getting-started.md) — one guided change from an
  empty configuration through review and undo, on a throwaway project.
- [Installation](manual/installation.md) — release and source prerequisites,
  installer PATH behavior, and optional local-model dependencies.
- [Interactive TUI](manual/interactive.md) — workspace trust preflight,
  starting and resuming, composer workflows, modes, decisions, and worktree
  review.
- [Custom commands](manual/custom-commands.md) — trusted prompt templates,
  discovery precedence, argument and file expansion, and inspection.
- [Providers and accounts](manual/providers.md) — authentication, credential
  precedence, readiness, model selection, and compatible local servers.
- [Instructions and skills](manual/instructions-and-skills.md) — `AGENTS.md`,
  project guidance, skill authoring and discovery, budgets, and inspection.
- [Configuration](manual/configuration.md) — config files, precedence,
  trust-gated project config, notifications, themes, subagent limits, and the
  `mentat config` commands.
- [Security](manual/security.md) — the default posture, data leaving the
  machine, the three boundaries, and inspecting the effective policy.
- [Permission policy](manual/permissions.md) — evaluation order, review
  behavior, conversation grants, and blocked headless runs.
- [Permission rules](manual/permission-rules.md) — durable policy matcher JSON,
  evaluation order, and safe authoring guidance.
- [Command sandbox](manual/sandbox.md) — modes, read scope, writable and
  protected paths, network policy, child environments, and backends.
- [Workspace trust](manual/workspace-trust.md) — activation, restricted
  operation, and the config allowlist.
- [Sessions](manual/sessions.md) — storage, lifecycle commands, diffs, and
  reverts.
- [Headless runs](manual/headless.md) — restricted unknown workspaces,
  scripting, images, output schemas, JSONL events, exit codes, and continuation.
- [Daemon and web](manual/daemon-and-web.md) — the opt-in resident daemon's
  lifecycle, plus the loopback browser frontend.
- [Shell completions](manual/completions.md) — zsh, bash, and PowerShell setup.
- [Troubleshooting](manual/troubleshooting.md) — where logs, crash reports, and
  state live, what they contain, and what to send when reporting a problem.

## Maintainer documentation

- [Architecture](architecture.md) — cross-library ownership boundaries and the
  main execution, persistence, workspace, and security flows.
- [Error model](dev/error-model.md) — programmer errors, recoverable boundary
  errors, durable workflow facts, fatal faults, and containment seams.
- [Performance](dev/performance.md) — launch, render-loop, and test-suite cost
  models.
- [Deterministic TUI tests](dev/tui-testing.md) — the in-process harness,
  virtual clock, and settling rules.
- [Evaluation and the research lab](dev/lab.md) — the eval instrument, session
  capture and trace analysis, subject blindness, and the `mentat-lab` campaign
  loop.

## Sources of truth

Public OCaml API contracts live in `.mli` files. They define types,
invariants, errors, effects, and the intended composition path for each module.
Markdown does not repeat those item-by-item contracts.

This directory is for material that needs a wider view:

- `manual/` documents user workflows and observable CLI behavior;
- `architecture.md` documents relationships spanning several libraries;
- `dev/` documents contributor procedures and project-wide engineering rules.

Tests are the executable source of truth for exact CLI output and TUI frames.
Temporary plans, investigations, and reviews may exist while work is active,
but they are not living product or API documentation and should be removed or
archived when their decisions have landed.
