# Charters

A charter is a standing review grant: one directory of policy you write once,
after which mentat reviews the pull requests of one GitHub repository
unattended and posts the findings back — inline threads for blocking findings
plus one summary comment, exactly as the [GitHub review](github-review.md)
pipeline renders them. Each run is a sealed [headless](headless.md) review
turn over an ephemeral checkout; what the charter adds is the standing part:
which events trigger a run, which are worth one, what a run may spend, and
the durable record of every decision.

A charter can only review. The run is always workflow mode `review` in an
enforced read-only sandbox, an unattended permission ask can only be denied
or park the run, and there is no write grant of any kind: nothing a charter
runs can push to, merge, or otherwise modify the repository. The one write
it performs —
posting the review comments — happens outside the run, with a separate
credential.

## What a charter is

A charter is a directory holding a `charter.json`, the prompt file it names,
the findings-schema file it names, and a `secrets/` directory for its
credentials. This example carries every commonly-set member; it installs
as-is:

```json
{ "charter": 1, "name": "pr-review",
  "workspace": { "repo": "acme/widgets" },
  "trigger": [
    { "kind": "github_webhook",
      "events": ["pull_request.opened", "pull_request.synchronize",
                 "pull_request.ready_for_review", "pull_request.reopened"],
      "gate": { "base": ["main"], "drafts": false,
                "associations": ["OWNER", "MEMBER", "COLLABORATOR"] } },
    { "kind": "cli" } ],
  "run": { "mode": "review", "prompt": "prompt.md",
           "output_schema": "findings.schema.json" },
  "budget": { "per_run": { "wall_clock": "15m" },
              "per_charter": { "usd_per_day": 15.0, "runs_per_hour": 6 } },
  "publish": { "github": "review-threads" },
  "notify": { "on": ["failed", "parked", "fenced"],
              "command": ["notify-send", "mentat charter"] } }
```

The `github_webhook` arm names the deliveries that trigger a run, each
`pull_request.<action>` from GitHub's documented action vocabulary; the `cli`
arm lets you fire the charter by hand, which the crontab deployment below
relies on. The prompt file is your review instructions; the schema file
constrains the findings document the run must produce (the shape
[GitHub review](github-review.md) documents). Reads are strict: an unknown
member anywhere, a typo'd event name, a mode other than `review`, or any
write-capable grant is a load error naming the offending member — never a
charter that silently never fires.

The knobs and their honest defaults:

| Member | Meaning |
| --- | --- |
| `gate.base` | Admitted base branches. Absent: any base. |
| `gate.drafts` | Whether draft pull requests are admitted. Absent: refused — a draft is not asking for review. A draft that goes ready is reviewed then. |
| `gate.associations` | Admitted author associations (GitHub's uppercase tokens, `OWNER` through `NONE`). Absent: any author. |
| `budget.per_run.wall_clock` | Required. The per-run wall-clock bound, digits then `s`, `m`, or `h`. |
| `budget.per_charter.usd_per_day` | Derived spend admitted over the trailing 24 hours. Absent: spend is unmetered. |
| `budget.per_charter.runs_per_hour` | Runs admitted over the trailing hour. Absent: 6 for webhook-shaped deliveries — a remote service is never an unmetered spender by omission. |
| `run.max_steps` | The step bound. Default 60. |
| `run.model`, `run.reasoning` | Model and reasoning-effort overrides. Absent: your configured defaults. |
| `permission_unattended` | `deny` records a model-visible denial and continues; `block` parks the run for a human. Absent: your configured `permission.unattended`, `block` by default. |
| `notify` | A hook command run on the named transitions (`failed`, `parked`, `fenced`); it receives one JSON event line on stdin. Optional. |
| `suppress.clean_run` | `"silent"`: a run that finds nothing posts no fresh comment (an existing summary still converges). |
| `enabled` | `false` stops admitting events without deleting anything. Default `true`. |

Installed charters live under `~/.config/mentat/charters/<name>`, their
receipt logs under `~/.local/state/mentat/charters/<name>`, and each run's
ephemeral checkout under `~/.cache/mentat/charters/<name>/runs`.

## The two credentials

A charter reads and writes GitHub with two fine-grained personal access
tokens, each a plain file under the charter directory's `secrets/`:

| File | Used for | Repository permissions |
| --- | --- | --- |
| `secrets/read-token` | The git fetch of the base branch and the pull request head, and three API reads: the pull request's current head, the open-PR listing, and the comments already posted. | Contents: read, Pull requests: read (plus the Metadata: read every fine-grained token carries). |
| `secrets/write-token` | Posting and patching the review comments — nothing else. | Pull requests: write. |

Create both tokens from the same account: the publisher decides which
existing comments are its own by the read credential's login, so a read and
a write token from different accounts would stack comments instead of
converging. Scope each token to the one repository the charter watches.

Write each file with a trailing newline or without — surrounding whitespace
is trimmed — and keep it owner-only: `chmod 600`. A charter directory or
secret readable by group or world is refused at load, the way sshd refuses
a loose key.

The write token is optional. Without it, reviews still run and the receipt
records that publication was skipped — useful while you trial a charter
before letting it comment.

Consider a dedicated machine account. Both tokens minted by your own account
make every review comment appear as you, personally. A separate account
(invited to the repository with read access, plus the token permissions
above) keeps the reviews clearly attributed to the automation, and its
tokens revocable without touching your own.

## Installing

```sh
mentat charter add ./pr-review
```

`add` validates the directory (or a path to its `charter.json`) and installs
it under its own name, printing the charter's policy digest and — for a
webhook charter, on first install — the two pieces of webhook identity it
mints: the ingress URL path (`/ingress/github/` followed by a random
32-character token) and the HMAC secret at `secrets/webhook`. Re-adding
after an edit replaces the policy files and keeps the identity, so your
edits never move the webhook URL; editing the installed directory in place
works too, since the files themselves are the registration. A proposal you
install from must not carry `secrets/` or `ingress.id` — secrets never ride
a proposal, and identity is minted at install.

The policy digest identifies what the three policy files say. Editing any of
them moves it, which resets the budget windows and re-admits every open
head — the deliberate re-review path.

`mentat charter rotate-secret NAME` re-mints the webhook HMAC secret in
place; the URL never moves. The old secret stops verifying the moment the
verb returns, so set the new one on the GitHub hook immediately — deliveries
signed with the old secret answer 401 until you do, and the sweep converges
whatever the gap missed. `mentat charter remove NAME` deletes the
configuration, secrets and webhook identity included (a later re-add mints a
fresh URL), and deliberately keeps the receipts: they are the audit trail.

## Running it with a crontab line

The smallest complete deployment is one crontab line — no daemon, no tunnel,
no inbound URL:

```
*/15 * * * * /usr/local/bin/mentat charter fire pr-review --sweep >>"$HOME/pr-review.log" 2>&1
```

`fire --sweep` lists the repository's open pull requests once with the read
token, then drives every head that has not been reviewed under the current
policy through the full pipeline: gate, budget fences, hardened checkout,
the sealed review run, publication, receipts. The record makes the line
idempotent: a head already reviewed stays silent, a fresh push is a new head
and is reviewed, a draft is skipped until it goes ready, a fenced head
re-enters when its budget window frees, and a pass that finds an interrupted
run or an unfinished publication from an earlier pass settles or finishes
it — publication re-entry spends nothing and mints no run. Use the charter
above as-is: `--sweep` replays webhook-shaped deliveries, so the charter
needs its `github_webhook` arm for the events and its `cli` arm for the
by-hand invocation.

Give cron the binary's absolute path, and make sure the invoking user holds
a model credential ([Providers and accounts](providers.md)) — the review run
authenticates like any headless run. `mentat charter fire NAME --event
FILE` drives one saved webhook payload instead of a sweep, fenced exactly
as a live delivery.

## Running it resident

The daemon, `mentatd`, is also the resident charter node: it serves the
webhook ingress, drives admitted deliveries through the same pipeline the
CLI fire takes, and reconciles every charter's record — at boot and on a
ten-minute beat ([Daemon and web](daemon-and-web.md) covers the daemon
itself). Install it as a user service:

```sh
mentatd install --ingress-port 8990
```

This writes the user-level service unit — a launchd agent at
`~/Library/LaunchAgents/dev.invarianthq.mentatd.plist` on macOS, a systemd
user unit at `~/.config/systemd/user/mentatd.service` on Linux — and hands
it to the service manager, started at login and kept running. The daemon's
output is appended to `~/.local/share/mentat/daemon/daemon.log`. The unit
pins the setting that lets run children outlive the daemon: a stop, restart,
or crash of the service leaves mid-turn runs running, and the daemon adopts
them when it next boots. Re-running `mentatd install` with different flags
replaces the unit; `mentatd uninstall` removes it without touching the
store, the logs, or any running child.

`--ingress-port` binds a loopback listener that answers only the
`POST /ingress/github/…` family. Every delivery is authenticated end-to-end
by its HMAC signature, so any tunnel you already trust can point at it —
expose the port through the tunnel of your choosing and use its public
hostname in the webhook settings. Then, in the repository's **Settings →
Webhooks → Add webhook**:

- **Payload URL**: your tunnel's public address followed by the charter's
  printed path, `https://<your-host>/ingress/github/<token>`;
- **Content type**: `application/json` — the signature covers the raw JSON
  body, and a form-encoded payload is refused;
- **Secret**: the contents of the charter's `secrets/webhook`;
- **Events**: "Let me select individual events", then **Pull requests**
  only.

GitHub sends a ping on creation; the ingress answers it 202 and records
nothing, so a 202 under the hook's Recent Deliveries is your end-to-end
check. A delivery with a bad signature is a content-free 401. Charters
register by file: one installed or edited while the daemon runs is in force
at the next event, with no restart, and a daemon holding at least one
enabled webhook charter never stops itself as idle.

Be honest with yourself about residency: the machine must stay up and the
tunnel must stay pointed, because GitHub does not redeliver on its own. What
the node self-heals, it heals from its own record and from the repository:
at boot it settles runs a crash left open, then reconciles fully — and every
ten minutes after — finishing interrupted publications without a fresh run
and sweeping open pull requests, so a head that was opened or pushed while
the machine slept is reviewed on the next pass rather than lost. The
crontab line needs none of this; it is the same pipeline on your scheduler.

## Watching it

The daemon's [browser frontend](daemon-and-web.md#browser-frontend) serves a
read-only dashboard at `/charters`, needs-you first: runs parked on a
question, runs that failed without a publishable outcome, charters whose
configuration no longer loads, receipt logs that cannot be read, runs
holding past their wall clock, tripped budget fences, and publications
still owed all render above the fold, each
linking to its session; below sits the routine record, one row per charter —
state, digest, spend and rate against their fences, last disposition, and
the webhook ingress address. Every value is read fresh per request. The
page renders no controls; changing anything stays with the CLI. The
installed service unit does not carry `--web`, so the dashboard is available
when you run `mentatd --web` yourself; under the service, the CLI verbs
below are the status surface.

```sh
mentat charter list          # roster: name, digest, state, last disposition
mentat charter status        # per charter: budgets against their windows, last receipt
mentat charter runs NAME     # the disposition receipts, one line per decision
```

Every decision is a receipt line in
`~/.local/state/mentat/charters/<name>/receipts.jsonl` — delivery, spawned,
reaped with usage and derived cost, published, alerted — append-only and
kept even after `charter remove`. A spawned receipt names the run's session
id, which is an ordinary session in the shared store: inspect or resume it
with the [session](sessions.md) verbs, and answer a parked run's pending
decision the way [Permission policy](permissions.md) documents for headless
runs.

The `notify` hook is the push channel: on each transition it names —
`failed` (a run settled without a publishable outcome), `parked` (a run
stopped on a question only a human can answer), `fenced` (a budget refused
an admission) — the configured command runs with one minified JSON event
line on stdin carrying the charter, transition, event identity, and session.
Output is discarded and a hook still running after five seconds is killed;
a notification is a courtesy, never an outcome.

## Money and safety

Two fences meter admission, both folded from the receipt log itself: derived
spend over the trailing 24 hours against `usd_per_day`, and spawned runs
over the trailing hour against `runs_per_hour`. When one trips, the event is
receipted `fenced`, the first trip in a window fires the notify hook (later
trips in the same window are receipted silently), and the head re-enters
when the window frees — a fence refusal never claims an event. The windows
trail the clock; there is no midnight reset. Spend is priced from each run's
recorded usage; a model the catalog cannot price contributes nothing to the
spend meter, leaving the run-count fence as that charter's effective leash.
Editing the policy resets both windows — that is the owner's deliberate
re-admission, not an accident to be avoided.

What a run can and cannot do: the checkout is fetched by hardened git — no
hooks, no prompts, no system or global configuration, the file and ext
transports closed — so fetching a hostile branch executes nothing from it.
The run child then works in that checkout under mode `review` with an
enforced read-only sandbox, and refuses to start if the sandbox cannot be
enforced; the diff and the files it touches are handed to the model as
material under review, never as instructions. The read token reaches git
per-invocation and never appears on a command line; the write token never
enters the run at all — it is read only for the short-lived publish step
after the run has ended, and a checkout layout that would place any secret
under the run's readable roots is refused before spawning. Ambient
`GITHUB_TOKEN` and `GH_TOKEN` variables are stripped from every child.

For GitHub Enterprise hosts, both the CLI fire and the daemon accept
overrides for the GitHub API base and the git host checkouts fetch from —
see `mentat charter fire --help` and `mentatd --help`.
