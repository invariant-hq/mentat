# Daemon and web

Every session is driven by its own agent — a `mentat` process the CLI and TUI
start and dial directly, with nothing to install or keep running. The daemon,
`mentatd`, is an opt-in resident process for the standing surfaces around
those agents: the browser frontend, and the resident node for standing review
grants — see [Routines](routines.md). It holds no engine and serves no
commands; nothing in `mentat` starts or requires one.

## Daemon lifecycle

The daemon is its own binary, `mentatd`, installed next to `mentat` by every
release. Run it in the foreground:

```sh
mentatd
```

Stop it gracefully with:

```sh
mentatd stop
```

Stopping when none is running is a successful no-op. A first SIGINT or SIGTERM
also performs a graceful stop; a second signal forces immediate exit if
teardown is stuck. Agents the daemon started — a browser action's session, a
routine's run — keep running across a daemon stop or crash and wind down on
their own.

To keep the daemon resident across logins, install it as a user service with
`mentatd install` (`mentatd install --print` renders the unit without touching
anything).

Only one daemon claims a data store. Its files live under `<data-home>/daemon`
(`~/.local/share/mentat/daemon` by default):

| Entry | Purpose |
| --- | --- |
| `daemon.json` | Pid, protocol and binary identity, config home, start time, the current web URL when `--web` is enabled, and the bound ingress address when an ingress listens. Written mode `0600`. |
| `daemon.lock` | Whole-life advisory claim; the lock, not the recorded pid, is the liveness authority. |
| `daemon.log` | Appended stdout/stderr for a service-managed daemon. |

## Captured configuration

The agents the daemon starts boot against the environment the daemon captured
when it started. Environment changes made only in a later shell do not alter
an already-running daemon; restart it after changing environment-provided
credentials or `MENTAT_*` settings its agents must consume. Credentials saved
to the shared auth store are read live by each agent.

## Browser frontend

Start an explicit foreground daemon from the project the browser should use:

```sh
cd /path/to/project
mentatd --web
```

`--web` binds IPv4 loopback only. Run by hand in a terminal it prints a URL
such as `http://127.0.0.1:PORT/?t=TOKEN`; under a service manager — where
standard output is the daemon log — the URL is recorded in `daemon.json`
(mode 0600) instead, so the access token never lands in a log file. It uses
an ephemeral port by default; choose one with `--web-port PORT`. The option
has no effect without `--web`. The web workspace is the daemon process's
startup working directory; there is no web `--cwd` flag.

The daemon is the browser's frontend exactly as the CLI is a terminal's: a
browser action against a dormant session starts the session's agent and dials
it, and the live feed rides that held connection. Sessions recorded in another
workspace still appear in the list, but driving one is refused — its agent
serves its own workspace — the same refusal `mentat run` gives a
cross-workspace resume.

Web startup does not show the TUI trust preflight. An unknown or explicitly
untrusted startup workspace remains restricted, with project config,
instructions, skills, commands, and project processes inactive. Record a
deliberate decision with `mentat trust /path/to/project` before starting the
web daemon when those repository-controlled inputs are required.

Starting and opening the UI does not itself require a model credential or make
a model request. A turn uses the currently configured model normally, so a
hosted model must be configured and authenticated before that turn can
succeed. Model selection and login remain CLI/TUI workflows.

The current browser surface can:

- list and open sessions, load older transcript pages, and follow live updates;
- create sessions, submit or queue text prompts, clear a queue, and interrupt or
  compact a turn;
- answer permission, question, and plan decisions;
- rename, archive, restore, and delete sessions;
- show a worktree review summary.

It does not currently expose model/account settings, custom-command expansion,
image attachment, or output-schema input. A slash-leading browser prompt is
ordinary literal prompt text. For images and output schemas, use
[Headless runs](headless.md).

## Browser trust boundary

The browser listener uses cleartext HTTP on loopback; it is not a public server
and has no supported public bind. Do not expose it through port forwarding, a
reverse proxy, or a shared host.

Every route except content-free `GET /health` requires authentication. Opening
the printed URL consumes its single-use bootstrap token, sets an `HttpOnly`,
`SameSite=Strict` session cookie, and redirects to `/` so the token leaves the
address bar. The daemon rotates the token and atomically republishes a fresh URL
in owner-only `daemon.json`; existing cookies remain valid. Every response also
carries a strict Content-Security-Policy, and Host/Origin checks reject requests
outside the exact `127.0.0.1` and `localhost` origins for the bound port.

Treat the URL, `daemon.json`, and browser cookie as credentials to the running
agent. An agent's per-session Unix socket similarly trusts processes running
as the same OS user; it has filesystem permissions, not per-client tokens. The
web edge does not replace Mentat's other controls: workspace activation,
permission review, and command sandboxing still apply to operations requested
through the browser. Model and web-tool network activity remains governed by
[Data leaving your machine](security.md#data-leaving-your-machine).
