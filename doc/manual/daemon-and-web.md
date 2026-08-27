# Daemon and web

Mentat runs its engine in the invoking process by default. The daemon is an
opt-in local transport for sharing one store, provider runtime, and engine host
across clients. The browser frontend is a second opt-in on that daemon; it is not
a hosted service. The daemon also serves as the resident node for standing
review grants — see [Charters](charters.md).

## Daemon lifecycle

The daemon is its own binary, `mentatd`, installed next to `mentat` by every
release. Run it in the foreground:

```sh
mentatd
```

In another terminal, add `--attach` to a command that advertises the flag:

```sh
mentat --attach
mentat run --attach "Inspect the failing build"
mentat session list --attach
```

If no daemon is running, `--attach` starts `mentatd` detached, inheriting the
attaching process's current directory and environment, then connects to it. The
daemon binary is resolved next to the running `mentat`; set `MENTATD_BIN` to
name one elsewhere.
Without `--attach`, commands keep using their in-process client even while a
daemon exists.

Stop the daemon gracefully with:

```sh
mentatd stop
```

Stopping when none is running is a successful no-op. A first SIGINT or SIGTERM
also performs a graceful stop; a second signal forces immediate exit if teardown
is stuck.

Only one daemon claims a data store. Its discovery files live under
`<data-home>/daemon` (`~/.local/share/mentat/daemon` by default):

| Entry | Purpose |
| --- | --- |
| `daemon.json` | Socket path, pid, protocol and binary identity, config home, start time, and current web URL when enabled. Written mode `0600`. |
| `daemon.lock` | Whole-life advisory claim; the lock, not the recorded pid, is the liveness authority. |
| `daemon.log` | Appended stdout/stderr for a daemon started automatically by `--attach`. |

The default socket is
`/tmp/mentat-<uid>-<store-key>/mentat.sock`. Mentat creates the directory as
owner-only `0700` and the socket as `0600`. Use an absolute private directory
when the default is unsuitable:

```sh
mentatd --socket /short/private/path
```

The override directory must be owned by the current user and mode `0700` and
cannot sit under a world-writable non-sticky parent. The selected socket is
recorded in `daemon.json`, so normal attachers follow it.

`MENTAT_DAEMON_SOCKET=/path/to/mentat.sock` is a lower-level client override. It
bypasses discovery and spawning and connects directly to that socket. If the
socket does not answer, attachment fails; Mentat does not fall back to another
daemon. The normal workspace handshake still applies, but the discovery-file
binary and config-home identity check does not.

## Captured configuration and limitations

The daemon process makes provider calls with the environment it captured when it
started. Environment changes made only in a later attaching shell do not alter
an already-running daemon. Restart it after changing environment-provided
credentials or `MENTAT_*` settings that the daemon must consume. Credentials
saved to the shared auth store are loaded again when a provider client is built.
Per-run options carried by an attached command remain explicit turn inputs.

Config and trust staging and custom-command discovery/expansion occur in the
attaching client as well; the engine and session fence live in the daemon. A
binary or config-home mismatch is refused rather than silently replacing a live
daemon; stop it explicitly before attaching with a different installation or
config home.

Current attached-mode limits include:

- `--ephemeral` cannot be combined with `--attach`, because the daemon owns the
  durable per-user store;
- image attachment is not transported to a remote daemon, so use an in-process
  [headless run](headless.md) for `--image`;
- session export over `--attach` supports JSON only; text, Markdown, and HTML
  exports run offline;
- attached revert requires an explicit `--latest` or `--change` scope and does
  not support `--path`.

Use each command's `--help` as the authority for whether `--attach` is accepted.

## Browser frontend

Start an explicit foreground daemon from the project the browser should use:

```sh
cd /path/to/project
mentatd --web
```

`--web` binds IPv4 loopback only and prints a URL such as
`http://127.0.0.1:PORT/?t=TOKEN`. It uses an ephemeral port by default; choose one
with `--web-port PORT`. The option has no effect without `--web`. The web
workspace is the daemon process's startup working directory; there is no web
`--cwd` flag.

Web startup does not show the TUI trust preflight. An unknown or explicitly
untrusted startup workspace remains restricted, with project config,
instructions, skills, commands, and project processes inactive. Record a
deliberate decision with `mentat trust /path/to/project` before starting the web
daemon when those repository-controlled inputs are required.

Starting and opening the UI does not itself require a model credential or make a
model request. A turn uses the currently configured model normally, so a hosted
model must be configured and authenticated before that turn can succeed. Model
selection and login remain CLI/TUI workflows.

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
agent. The local Unix socket similarly trusts processes running as the same OS
user; it has filesystem permissions, not per-client tokens. The web edge does
not replace Mentat's other controls: workspace activation, permission review,
and command sandboxing still apply to operations requested through the browser.
Model and web-tool network activity remains governed by
[Data leaving your machine](security.md#data-leaving-your-machine).
