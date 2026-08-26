# Troubleshooting

When Mentat misbehaves, three artifacts explain it: the session document, which
records what the agent did; the diagnostics log, which records what the process
did; and a crash report, written only when an internal invariant fails. This
page says where each lives, what it contains, and what to send when reporting a
problem.

## Where Mentat keeps things

Three roots, each resolved the same way: an absolute `MENTAT_*_HOME` override
wins, else `XDG_*_HOME/mentat`, else the `$HOME` fallback. A relative override is
a hard error.

| Root | Override | Default | Holds |
| --- | --- | --- | --- |
| Config | `MENTAT_CONFIG_HOME` | `~/.config/mentat` | `config.json`, `auth.json`, `trust.json`, `keybindings.json` |
| Data | `MENTAT_DATA_HOME` | `~/.local/share/mentat` | the session store, the daemon directory |
| State | `MENTAT_STATE_HOME` | `~/.local/state/mentat` | `logs/`, `crashes/`, `history.jsonl` |

`mentat doctor` prints a pass/warn/fail line per subsystem and makes no model
request. Its `config`, `storage`, and `diagnostics` lines name the three roots as
resolved on this machine, and `diagnostics` warns when crash reports are waiting.
`mentat sandbox status` and `mentat sandbox explain` report the sandbox posture
the same way.

## Diagnostics logs

Logging is deliberately quiet by default, and the default differs by frontend
because the interactive terminal owns the screen.

| Frontend | Default level | Destination |
| --- | --- | --- |
| Interactive terminal | `info` | `<state_home>/logs/<run>.log`, newest 20 kept |
| Headless (`run`, `session`, `config`, …) | off | standard error, only when `MENTAT_LOG` is set |
| Daemon (`mentatd`) | off | `<data_home>/daemon/daemon.log`, which captures the daemon's standard output and error |

A spawned daemon inherits the environment of the command that started it, so
setting `MENTAT_LOG` before a `--attach` run also raises the daemon's level.

`-v` raises the level to `info` for one run and `-vv` to `debug`:

```sh
mentat -v run start "..."
mentat -vv doctor
```

Both are read before any command starts, so they cover startup too, and both
override `MENTAT_LOG`. Raising the level never lifts the ceiling on linked
libraries described below, so `-vv` cannot put a request body or a credential on
disk.

`MENTAT_LOG` selects the level for longer — `quiet`, `error`, `warning`, `info`,
or `debug` — and `MENTAT_LOG_FILE` redirects records to an absolute path,
appended, for either frontend. Both are read once at process start; changing them
requires a restart. Diagnostics never reach standard output, which carries
results.

The terminal always diverts to a file, since a record written to the screen
would corrupt it. `<state_home>/logs/latest.json` names the current run's file:

```sh
cat ~/.local/state/mentat/logs/latest.json
```

Each run writes one file named for its run id, and the newest twenty are kept.
A record is always one physical line, so the files are safe to `grep`.

### What a log contains

A log records what the process did, never what you asked or what the model
answered. Only the resolved subcommand token is recorded from the command line,
because a positional argument can carry prompt text. No Mentat log record
contains a message body, a tool argument, or a credential.

`MENTAT_LOG` governs Mentat's own records only. Libraries Mentat links declare
their own and are held at `warning` whatever you set, because some of them —
notably the HTTP client — write whole requests and responses at `debug`,
including the `Authorization` header. Raising `MENTAT_LOG` therefore does not
put your conversation or your API key on disk.

This is a property of the log, not of the session. The conversation lives in the
session document, and exporting it is a separate, deliberate act.

## Crash reports

An internal invariant violation exits `125`, prints one line to standard error
naming the saved report, and never prints a backtrace to the terminal:

```
mentat: internal error: <message> (report saved: ~/.local/state/mentat/crashes/<run>.log)
```

The report is written `0600` and the newest twenty are kept. It is meant to
travel on its own: above the backtrace it carries the Mentat version, run id,
pid, active session, the subcommand, `TERM`, the OCaml version, this run's log
path, and that run's last records copied out of the log — so it stays readable
even if the log has since rotated away.

Ordinary failures are not crashes. A bad configuration value, an unreachable
provider, or a missing session exits `1` or `2` with a `mentat:` message and
writes no report.

## Correlating a session

Given a session, `mentat debug session` resolves its on-disk artifacts and finds
the log and crash files that mention it:

```sh
mentat debug session --last          # the newest session in this workspace
mentat debug session SESSION --json
```

It reports the session's state, its `session.json` and `ledger.jsonl`, every log
file whose records are attributed to it, every crash report naming it, and the
follow-up commands worth running. Sessions are targeted by id or unique id
prefix; use `mentat session list` or `mentat session search` to find one by
title.

## Reporting a problem

`mentat report` collects the evidence for you into one NDJSON file:

```sh
mentat report --last --note "the agent edited a file I did not name"
mentat report SESSION -o report.ndjson
mentat report --no-session          # when Mentat will not start at all
```

Each line is one record:

| Record | What it holds |
| --- | --- |
| `report` | Mentat version, platform, terminal, locale |
| `doctor` | the same checks `mentat doctor` prints |
| `config` | effective configuration with provenance, credentials redacted |
| `session` | the session's state and the paths of its stored files |
| `log`, `crash` | the diagnostics files whose records name that session |
| `session_export` | the whole conversation, only with `--with-session-export` |
| `manifest` | a count and a digest over every preceding line |

The manifest makes a truncated bundle detectable rather than silently short.

`mentat report` prints what it is about to collect and asks before writing. When
standard input is not a terminal it declines unless you pass `--yes`. It uploads
nothing; sending the file is your decision.

By default the bundle carries the session's *state*, not its conversation. Add
`--with-session-export` to include the conversation — every prompt, every reply,
and the source and command output its tools returned. That is usually the most
useful thing a maintainer can have and the most revealing thing you can send, so
read it first. It is nested whole rather than merged in, which keeps the export's
own integrity manifest verifiable on its own terms.

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for what makes a report useful and
[SECURITY.md](../../SECURITY.md) for anything with a security impact — those go
through private vulnerability reporting, never a public issue.

Read anything before you attach it. A session export contains your prompts and
can contain source from the workspace. Two files deserve particular care and are
never worth attaching wholesale:

- `<config_home>/auth.json` holds provider credentials.
- `<state_home>/history.jsonl` holds your composer history across every project,
  not just this one.

The daemon's `daemon.log` also needs a look before sharing. It captures the
daemon's standard output rather than only its diagnostics records, and it is not
rotated, so it accumulates for the life of the data home. A daemon Mentat spawns
for you withholds the browser frontend's bootstrap token from it — a URL printed
to a log file no one reads would persist a live credential for nothing — but a
daemon you started yourself with `mentatd --web` prints that URL to its own
standard output, wherever you redirected it.
