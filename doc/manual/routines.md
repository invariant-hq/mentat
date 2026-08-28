# Routines

A routine is a standing review grant: one directory of policy you write once,
after which mentat reviews the pull requests of one GitHub repository
unattended and posts the findings back — inline threads for blocking findings
plus one summary comment, exactly as the [GitHub review](github-review.md)
pipeline renders them. Each run is a sealed [headless](headless.md) review
turn over an ephemeral checkout; what the routine adds is the standing part:
which events trigger a run, which are worth one, what a run may spend, and
the durable record of every decision.

A routine can only review. The run is always workflow mode `review` in an
enforced read-only sandbox, an unattended permission ask can only be denied
or park the run, and there is no write grant of any kind: nothing a routine
runs can push to, merge, or otherwise modify the repository. The one write
it performs —
posting the review comments — happens outside the run, with a separate
credential.

## What a routine is

A routine is a directory holding a `routine.json`, the prompt file it names,
and the findings-schema file it names. This example carries every
commonly-set member; it installs as-is:

```json
{ "routine": 1, "name": "pr-review",
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
              "per_routine": { "usd_per_day": 15.0, "runs_per_hour": 6 } },
  "publish": { "github": "review-threads" },
  "notify": { "on": ["failed", "parked", "fenced"],
              "command": ["notify-send", "mentatd routine"] } }
```

The `github_webhook` arm names the deliveries that trigger a run, each
`pull_request.<action>` from GitHub's documented action vocabulary; the `cli`
arm lets you fire the routine by hand, which the crontab deployment below
relies on. The prompt file is your review instructions; the schema file
constrains the findings document the run must produce (the shape
[GitHub review](github-review.md) documents). Reads are strict: an unknown
member anywhere, a typo'd event name, a mode other than `review`, or any
write-capable grant is a load error naming the offending member — never a
routine that silently never fires.

The knobs and their honest defaults:

| Member | Meaning |
| --- | --- |
| `gate.base` | Admitted base branches. Absent: any base. |
| `gate.drafts` | Whether draft pull requests are admitted. Absent: refused — a draft is not asking for review. A draft that goes ready is reviewed then. |
| `gate.associations` | Admitted author associations (GitHub's uppercase tokens, `OWNER` through `NONE`). Absent: any author. |
| `budget.per_run.wall_clock` | Required. The per-run wall-clock bound, digits then `s`, `m`, or `h`. |
| `budget.per_routine.usd_per_day` | Derived spend admitted over the trailing 24 hours. Absent: spend is unmetered. |
| `budget.per_routine.runs_per_hour` | Runs admitted over the trailing hour. Absent: 6 for webhook-shaped deliveries — a remote service is never an unmetered spender by omission. |
| `run.max_steps` | The step bound. Default 60. |
| `run.model`, `run.reasoning` | Model and reasoning-effort overrides. Absent: your configured defaults. |
| `permission_unattended` | `deny` records a model-visible denial and continues; `block` parks the run for a human. Absent: your configured `permission.unattended`, `block` by default. |
| `notify` | A hook command run on the named transitions (`failed`, `parked`, `fenced`); it receives one JSON event line on stdin. Optional. |
| `suppress.clean_run` | `"silent"`: a run that finds nothing posts no fresh comment (an existing summary still converges). |
| `enabled` | `false` stops admitting events without deleting anything. Default `true`. |

Installed routines live under `~/.config/mentat/routines/<name>`, their
receipt logs under `~/.local/state/mentat/routines/<name>`, and each run's
ephemeral checkout under `~/.cache/mentat/routines/<name>/runs`.

## Connecting to GitHub: your own App

Routines authenticate to GitHub through a GitHub App you own — created
once, serving every routine. One verb creates it:

```sh
mentatd github setup
```

The browser opens on GitHub's own "Create GitHub App" page, pre-filled: a
generated name (App names are global on GitHub, so the pre-fill carries a
random suffix — edit it in place if you prefer; if the name is taken,
GitHub's page says so), the three permissions the pipeline needs (Contents:
read, Pull requests: write, Metadata: read), and the `pull_request` event.
One click on **Create GitHub App**, and the verb finishes: GitHub redirects
back with a one-time code, mentat exchanges it, and the App's credentials —
its identity, its private key, its webhook secret — land in
`~/.config/mentat/github-app`, owner-only files written atomically. (The
client secret GitHub also returns is deliberately discarded: nothing here
performs user OAuth, and an unused credential on disk is pure liability.)

Then install the App on the repositories your routines watch — the verb
prints the link (`https://github.com/apps/<name>/installations/new`);
GitHub's own page, one more click, one repository or all of them. That is
the whole journey:

```sh
mentatd routine add ./pr-review
```

No token minted, no secret pasted, no webhook configured on the repository.
Reviews post as `<name>[bot]` — attributed to the automation, revocable in
one place (the App's GitHub settings page) without touching anyone's
personal tokens — and every credential the pipeline actually uses is a
short-lived installation token minted per fire, scoped to the one
repository the routine watches: the read-scoped token feeds the fetch and
the API reads, a write-scoped token exists only for the seconds a
publication takes, and nothing expires on a calendar you have to remember.

`mentatd github status` is the pre-flight doctor: locally, that the
credential home is present, complete, and private, and which auth mode each
routine is in; over the network, that the App still exists and the stored
key still signs, that the webhook configuration matches your local files,
and that each routine's repository is covered by an installation — with the
install link printed when one is not. Run it when anything looks wrong.

Adding a second repository later: if the App was installed on all
repositories, `mentatd routine add ./other-review` is the entire journey;
if per-repository, one click on the same installations page first.

Setup wants a browser on the machine. On a headless box, run `mentatd
github setup` wherever a browser lives and copy `~/.config/mentat/github-app`
over — provisioning is files. For GitHub Enterprise hosts, pass
`--github-base-url`; the base is recorded with the App, and a node
configured for a different host refuses the credentials loudly rather than
sending them to the wrong place.

There is no `github remove`: the credential home is files, so removal is
`rm -r ~/.config/mentat/github-app` — and the App itself is deleted from
its GitHub settings page (no API deletes an App).

## Installing

```sh
mentatd routine add ./pr-review
```

`add` validates the directory (or a path to its `routine.json`) and installs
it under its own name, printing the routine's policy digest and its auth
mode — which App it posts through, or that it runs on personal access
tokens (the [fallback](#fallback-personal-access-tokens) below), or that
neither is set up yet. Editing the installed directory in place works too,
since the files themselves are the registration; re-adding after an edit
replaces the policy files. A proposal you install from must not carry
`secrets/` — secrets never ride a proposal.

The policy digest identifies what the three policy files say. Editing any of
them moves it, which resets the budget windows and re-admits every open
head — the deliberate re-review path.

`mentatd routine remove NAME` deletes the routine's configuration and
deliberately keeps the receipts: they are the audit trail.

## Running it with a crontab line

The smallest complete deployment is one crontab line — nothing resident, no
tunnel, no inbound URL, no webhook. `mentatd` here is a one-shot command: it
runs the pipeline in the invoking process and exits.

```
*/15 * * * * /usr/local/bin/mentatd routine fire pr-review --sweep >>"$HOME/pr-review.log" 2>&1
```

`fire --sweep` lists the repository's open pull requests once, then drives
every head that has not been reviewed under the current policy through the
full pipeline: gate, budget fences, hardened checkout, the sealed review
run, publication, receipts. The record makes the line idempotent: a head
already reviewed stays silent, a fresh push is a new head and is reviewed, a
draft is skipped until it goes ready, a fenced head re-enters when its
budget window frees, and a pass that finds an interrupted run or an
unfinished publication from an earlier pass settles or finishes it —
publication re-entry spends nothing and mints no run. Use the routine
above as-is: `--sweep` replays webhook-shaped deliveries, so the routine
needs its `github_webhook` arm for the events and its `cli` arm for the
by-hand invocation.

Give cron the binary's absolute path, and make sure the invoking user holds
a model credential ([Providers and accounts](providers.md)) — the review run
authenticates like any headless run. `mentatd routine fire NAME --event
FILE` drives one saved webhook payload instead of a sweep, fenced exactly
as a live delivery.

## Running it resident

The daemon, `mentatd`, is also the resident routine node: it serves the
webhook ingress, drives admitted deliveries through the same pipeline the
CLI fire takes, and reconciles every routine's record — at boot and on a
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
expose the port through the tunnel of your choosing, then route the App's
one webhook at its public hostname:

```sh
mentatd github repoint https://hooks.example.com
```

That single verb points deliveries for *every* installed repository at your
node — the App has one webhook, and its configuration on GitHub is a
projection of your local files, so re-running the verb after a failure or a
tunnel move converges. Until you repoint, the webhook targets an unroutable
placeholder: undelivered pings show as red lines in the App's delivery log
on GitHub and nothing else, and the reconcile sweep keeps reviews flowing
without a webhook at all.

`mentatd github rotate-secret` re-mints the webhook's HMAC secret and
updates GitHub in the same motion — the one-verb rotation for every
routine's deliveries at once. Deliveries signed with the old secret answer
401 until the update lands, and the sweep covers whatever the gap misses.

Routines register by file: one installed or edited while the daemon runs is
in force at the next event, with no restart, and a daemon holding at least
one enabled webhook routine never stops itself as idle.

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
read-only dashboard at `/routines`, needs-you first: runs parked on a
question, runs that failed without a publishable outcome, routines whose
configuration no longer loads, receipt logs that cannot be read, runs
holding past their wall clock, tripped budget fences, and publications
still owed all render above the fold, each
linking to its session; below sits the routine record, one row per routine —
state, digest, spend and rate against their fences, last disposition, and
the webhook ingress address. Every value is read fresh per request. The
page renders no controls; changing anything stays with the CLI. Under the
service, pass `--web` (and `--web-port` to pin the port) to
`mentatd install`, which bakes the frontend into the unit's exec line —
only one daemon claims a store, so this is the only way a service-managed
node serves the dashboard; the URL to open, bootstrap token included, is
recorded in `daemon.json`, never printed to the service log. Running
`mentatd --web` yourself works the same without the service, and the CLI
verbs below are the status surface either way.

```sh
mentatd routine list          # roster: name, digest, state, auth mode, last disposition
mentatd routine status        # per routine: auth, budgets against their windows, last receipt
mentatd routine runs NAME     # the disposition receipts, one line per decision
mentatd github status         # the App doctor: credentials, hook, installations
```

Every decision is a receipt line in
`~/.local/state/mentat/routines/<name>/receipts.jsonl` — delivery, spawned,
reaped with usage and derived cost, published, alerted — append-only and
kept even after `routine remove`. A spawned receipt names the run's session
id, which is an ordinary session in the shared store: inspect or resume it
with the [session](sessions.md) verbs, and answer a parked run's pending
decision the way [Permission policy](permissions.md) documents for headless
runs.

The `notify` hook is the push channel: on each transition it names —
`failed` (a run settled without a publishable outcome), `parked` (a run
stopped on a question only a human can answer), `fenced` (a budget refused
an admission) — the configured command runs with one minified JSON event
line on stdin carrying the routine, transition, event identity, and session.
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
spend meter, leaving the run-count fence as that routine's effective leash.
Editing the policy resets both windows — that is the owner's deliberate
re-admission, not an accident to be avoided.

What a run can and cannot do: the checkout is fetched by hardened git — no
hooks, no prompts, no system or global configuration, the file and ext
transports closed — so fetching a hostile branch executes nothing from it.
The run child then works in that checkout under mode `review` with an
enforced read-only sandbox, and refuses to start if the sandbox cannot be
enforced; the diff and the files it touches are handed to the model as
material under review, never as instructions. The read credential reaches
git per-invocation and never appears on a command line; the write
credential never enters the run at all — in App mode it is minted only for
the short-lived publish step after the run has ended, and in PAT mode the
token file is read only then. The App's private key never enters any child
process, any command line, or any file outside the credential home; only
minted tokens flow. A checkout layout that would place any secret under the
run's readable roots is refused before spawning, and ambient `GITHUB_TOKEN`
and `GH_TOKEN` variables are stripped from every child.

## Fallback: personal access tokens

An owner who cannot create an App (organization policy), watches a
non-GitHub forge, or simply prefers tokens can run any routine on two
fine-grained personal access tokens instead. Write them as plain files
under the routine directory's `secrets/`, and that routine is a PAT
routine — the presence of either file decides the mode, per routine, and
every roster surface (`add`, `list`, `status`, the doctor) names which mode
each routine is in:

| File | Used for | Repository permissions |
| --- | --- | --- |
| `secrets/read-token` | The git fetch of the base branch and the pull request head, and three API reads: the pull request's current head, the open-PR listing, and the comments already posted. | Contents: read, Pull requests: read (plus the Metadata: read every fine-grained token carries). |
| `secrets/write-token` | Posting and patching the review comments — nothing else. | Pull requests: write. |

Create both tokens from the same account: the publisher decides which
existing comments are its own by the posting identity, so a read and a
write token from different accounts would stack comments instead of
converging. Scope each token to the one repository the routine watches, and
mind the expiry date GitHub imposes on fine-grained tokens — re-minting
them on time is yours to remember in this mode.

Write each file with a trailing newline or without — surrounding whitespace
is trimmed — and keep it owner-only: `chmod 600`. A routine directory or
secret readable by group or world is refused at load, the way sshd refuses
a loose key. The write token is optional: without it, reviews still run and
the receipt records that publication was skipped — useful while you trial a
routine before letting it comment.

A PAT routine carries its own webhook identity, minted by `add` once a
token file is present (installing before writing the tokens? re-run `add`
on the installed directory — the load error says so): the ingress URL path
(`/ingress/github/` followed by a random 32-character token) and the HMAC
secret at `secrets/webhook`. Re-adding after an edit replaces the policy
files but never the identity, so your edits never move the webhook URL. For
a resident node, each PAT routine's webhook is configured per repository,
in **Settings → Webhooks → Add webhook**:

- **Payload URL**: your tunnel's public address followed by the routine's
  printed path, `https://<your-host>/ingress/github/<token>`;
- **Content type**: `application/json` — the signature covers the raw JSON
  body, and a form-encoded payload is refused;
- **Secret**: the contents of the routine's `secrets/webhook`;
- **Events**: "Let me select individual events", then **Pull requests**
  only.

GitHub sends a ping on creation; the ingress answers it 202 and records
nothing, so a 202 under the hook's Recent Deliveries is your end-to-end
check. A delivery with a bad signature is a content-free 401.
`mentatd routine rotate-secret NAME` re-mints a PAT routine's webhook HMAC
secret in place; the URL never moves, and the old secret stops verifying
the moment the verb returns — set the new one on the GitHub hook
immediately. (On an App routine that verb refuses: App deliveries verify
against the owner-level secret, which `mentatd github rotate-secret`
rotates.)

Switching a routine between modes is a credential change, not a policy
change — the digest does not move and settled heads stay settled. One
migration wart, stated plainly: comments posted under one identity are
invisible to the other's convergence filter, so a pull request reviewed
under both identities across a switch carries the old identity's summary
until you delete it, and a still-standing finding whose thread the old
identity posted is re-posted once by the new one. One time, per straddling
pull request, at switch.

For GitHub Enterprise hosts, both the CLI fire and the daemon accept
overrides for the GitHub API base and the git host checkouts fetch from —
see `mentatd routine fire --help` and `mentatd --help`.
