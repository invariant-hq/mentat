# Mentat manual

User-facing documentation for the `mentat` binary. For design documents and
internal notes, see the rest of [`doc/`](../).

- [Getting started](getting-started.md) — one guided change from an empty
  configuration through review and undo, on a throwaway project.
- [Installation](installation.md) — release and source prerequisites, installer
  PATH behavior, and optional local-model dependencies.
- [Interactive TUI](interactive.md) — workspace trust preflight, starting and
  resuming, composer workflows, modes, decisions, and worktree review.
- [Custom commands](custom-commands.md) — trusted prompt templates, discovery
  precedence, argument and file expansion, and offline inspection.
- [Providers and accounts](providers.md) — authentication, credential
  precedence, readiness, model selection, and compatible local servers.
- [Instructions and skills](instructions-and-skills.md) — `AGENTS.md`, project
  guidance, skill authoring and discovery, budgets, and inspection.
- [Configuration](configuration.md) — config files, precedence, trust-gated
  workspace filtering, notifications, themes, subagent limits, and inspection.
- [Security](security.md) — the default posture, what leaves your machine, the
  three boundaries, and how to inspect the effective policy.
- [Permission policy](permissions.md) — how an operation is allowed, denied, or
  sent to review; review behavior, grants, and blocked headless runs.
- [Permission rules](permission-rules.md) — durable rule precedence, matcher
  JSON, authoring, inspection, and removal.
- [Command sandbox](sandbox.md) — modes, filesystem read scope, writable and
  protected paths, network policy, child environments, and backends.
- [Workspace trust](workspace-trust.md) — activation, what a restricted
  workspace can still do, and the config allowlist that survives trust.
- [Sessions](sessions.md) — where sessions live and how to list, resume,
  fork, rewind, diff, and revert them.
- [Headless runs](headless.md) — `mentat run` for scripts and CI: run flags,
  images, output schemas, JSONL events, exit codes, and continuation.
- [GitHub review](github-review.md) — the two-half review pipeline: producing
  a findings document, rendering it into GitHub API requests, and posting.
- [Routines](routines.md) — standing, unattended pull-request review: the
  routine directory, credentials, crontab or resident deployment, budgets,
  and the durable record.
- [Daemon and web](daemon-and-web.md) — opt-in `--attach`, daemon lifecycle and
  local socket trust, plus the authenticated loopback browser frontend.
- [Shell completions](completions.md) — installing cmdliner completion
  for zsh, bash, and PowerShell.
- [Troubleshooting](troubleshooting.md) — where logs, crash reports, and state
  live, what they contain, and what to send when reporting a problem.
