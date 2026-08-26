# RFC 0024: Charters and mentatd — the always-on layer

- Status: `discussion`. (Lifecycle: `ideation → discussion → published →
  committed | abandoned`. Provenance: a 12-question code audit at HEAD
  ~`60006797e`, four blind whole-designs, an adjudication, four adversarial
  lenses — shape, simplicity, correctness/security, cost — and a
  simplification survey, all folded; anchors below were re-verified from
  source by the correctness lens. A maintainer-directed rework then
  replaced three decisions that had optimized for distance-from-HEAD over
  final shape — the resident layer is its own binary, provenance is typed
  in the journal, the publisher's end state is in-process — under the
  standing directive that the RFC carries the right design and stages
  migrations as migrations, never as destinations.)
- Audience: Mentat maintainers; the architecture (RFC 0000), server
  (RFC 0017), subagent-process (RFC 0018), and GitHub connector
  (RFC 0019/0020) authors
- Derives from: RFC 0000 (the Method; D1, D5, D13, D16, D17; S3/S4/S5),
  RFC 0017 (the daemon builds almost nothing; the boundary invariant; the
  endpoint-descriptor table), RFC 0018 (laws L1–L10 and §7.4, consumed not
  amended), RFC 0019 (laws C1–C8; the findings document; the §4 advisory
  table; the §5 principal correction), RFC 0020 (the pure renderer; §10's
  resident-connector invariants), and the code seams cited inline.
- Amends: RFC 0000 S3 (§11.1) and D10/D11 (§11.4, ruled 2026-08-25);
  RFC 0020 §2/§9/§10 (§11.2); RFC 0017 (residency moves to the `mentatd`
  binary and the `Bind.public` constructor is deleted, §11.5); the wire
  and journal vocabulary (`Turn.Origin.Triggered` in, the goal
  vocabulary out — ordinary pre-deployment changes, no version bump,
  §11.6). S4 is realized, not amended (§11.3).
- Maintainer rulings (2026-08-25, fixed): the primitive is the **charter**;
  the first funded slice is **GitHub-webhook-reactive read-only PR review**;
  charter runs are **OS processes from day 1** with RFC 0018 funded; the
  **fleet** (multi-tenant hosting) is a separate product whose needs get
  invariants here, never machinery; this RFC formally amends S3;
  **the design must simplify mentat** (§13 carries the deletion ledger
  that makes the claim checkable); and **mentat is the agent only** —
  residency is a separate deliverable, `mentatd`, not a mode of the agent.

## Summary

Mentat's roadmap ladder — interactive → headless one-shot → scheduled →
event-driven → self-directed — stalls at rung two because three things do
not exist: nothing can admit a turn but a client or an engine continuation,
nothing inbound can reach the daemon, and nothing reaches the owner who is
not looking at a terminal. This RFC builds the always-on layer that fills
exactly those holes, in one sentence:

> **The node wakes; the engine admits; the owner hears exactly once.** A
> charter is an owner-written file binding a typed trigger to a sealed
> headless run; **`mentatd`** — the node, a separate binary owning all
> residency — turns authenticated deliveries into idempotent,
> money-fenced, OS-process runs of that file — admitted as typed,
> journal-recorded triggered turns — publishes what they find
> through the connector, records receipts, alerts once per transition,
> and re-derives everything else by folding run journals and observing
> GitHub.

**The three deliverables.** This RFC fixes the product decomposition:

- **`mentat` — the agent, and only the agent.** The TUI and `mentat run`,
  in-process, journal-durable, no daemon. It sheds `mentat serve`: an
  agent needs no residency, and the code already agrees — the engine
  never links the server, and the daemon is opt-in today.
- **`mentatd` — one owner's resident host.** One process owning
  everything resident: the webhook ingress, charters and their receipts,
  the reconcile sweep, spawn/reap of runs, the RFC 0018 child broker,
  and the existing attachment surfaces (`--attach`, the web mount),
  whose composition moves here from `mentat serve`. It runs wherever
  that owner wants residency — a laptop for the web UI, a VPS for
  always-on — and it spawns `mentat` processes beside it, so the two
  binaries always deploy together and ship in one release artifact
  (which is what keeps node/runner version skew a refusal corner rather
  than a routine hazard, §11.5). **mentatd is single-owner by law**: one owner, one trust
  domain, that owner's files. It is the BEAM decomposition, drawn
  honestly: the supervisor lives with the runtime that spawns the
  workers; the workers are separate processes; the external watchdog is
  the OS unit.
- **The fleet — not mentat, not mentatd.** The multi-owner product
  (identity, billing, tenancy) runs many owners' mentatds and speaks
  their wire; §10 pins the invariants that keep that possible. The
  membership law from the concept phase stands: understands sessions,
  turns, and facts → mentat; serves more than one owner → fleet.

The organizing finding, confirmed at every anchor: **the engine already
contains the entire execution vehicle.** `mentat run start --mode review
--sandbox read-only --require-sandbox --permission-unattended deny
--output-schema … --json` is a complete, sealed, kernel-sandboxed,
exit-code-contracted review run (`bin/cli_run.ml:945-1073`;
`bin/exit_status.mli:9-13`), and RFC 0020's renderer is the complete
publication path. What GitHub Actions provides today and mentatd must
replace is four things: a trigger transport, a gate, a host that
survives between events, and a place the bill lands. Everything else in
this RFC is refusal — the funded slice adds **zero engine behavior
change** (no scheduler, no admission-path change beyond one vocabulary
arm) **and one deliberate vocabulary change, with no version bump**
(the wire is pre-deployment; §11.6): typed trigger provenance enters
the journal (`Turn.Origin.Triggered`, §3) and the goal vocabulary
leaves with §11.4 — a **net-smaller** vocabulary. §13
carries the deletion ledger honestly: the slice grows the tree while
shrinking its *surface* — the goal machinery (superseded as the
autonomy surface, ruled in §11.4), `mentat serve` as an agent
subcommand, the `Bind.public` constructor, and the pending 0022
auto-review design all go.

## 1. Laws

- **N1 — The node wakes; the engine admits.** No trigger, timer, or event
  source enters `lib/agent` or `lib/session`; the settled-idle engine
  blocks on its mailbox by design (`lib/agent/driver.ml:1772-1773`) and the
  node fills the hole from outside through existing verbs. *Prevents:* an
  engine scheduler; wake sources bypassing the admission ladder.
- **N2 — Charters are configuration; capability never comes from a
  workspace.** A charter is owner-written policy in the config home. No
  file in any checkout — trusted or not — can create, select, or widen one
  (C4 lifted to the charter layer). *Prevents:* a PR installing the policy
  that reviews it; the OpenClaw skill-registry class.
- **N3 — Receipt before acknowledgment.** A delivery becomes a durable
  receipt line — an fsynced append under the store's ledger discipline,
  with the `O_EXCL` marker as the creation barrier
  (`lib/store/disk.ml:110-119`), exactly as durable as the journal — before
  the ingress answers 202; a receipt that cannot be written is a 5xx. The
  residual power-loss window is closed by the reconcile sweep, not by a
  stronger barrier. *Prevents:* acknowledged-then-lost deliveries no
  reconcile can see.
- **N4 — Identity is content-derived at every layer.** Run session ids and
  receipt names derive from `(charter digest, event identity)`. Redelivery
  and re-spawn are no-ops or loud collisions, never silent duplicates.
  *Prevents:* duplicate reviews; unbounded work from at-least-once
  delivery.
- **N5 — The node holds no durable state of its own.** Everything it knows
  is a fold over durable inputs: charter files, receipts, run journals,
  fence probes, and the observed external system. Recovery *is* re-running
  the fold (Method rule 2 made structural). *Prevents:* a second source of
  truth; meters and flags that rot.
- **N6 — The lane law.** Read the run's journal head. Settled
  (`Completed | Failed | Step_limit | Interrupted`) ⇒ **semantic** failure:
  a human must see what the run said, and the boundary never manufactures
  a retry (D1, 0018 L6). Unsettled with a pending decision at the head ⇒
  **parked** — semantic lane, decision durable, never resumed by the node.
  Unsettled with no pending decision and a dead child ⇒ **process**
  failure: settle once honestly (§5), then dispose; failures of the
  resident machinery itself — node down, publisher failure, unwritable
  disk, version skew — ride the same process lane: never a PR advisory,
  surfaced on the hook and `mentatd status`, recovered mechanically. A
  wake that never becomes a run — gate skip, fence trip, dup, forged
  delivery, invalid charter — is a
  **node event**: receipt plus `mentatd status` plus the notify hook, never a
  PR advisory (there is no run to report, and a fence is charter-scoped,
  not PR-scoped). *Prevents:* auto-retry of judgment; corpses masquerading
  as rest; parked runs mis-disposed as failures.
- **N7 — Money-fenced, stop-and-alert.** The per-charter currency fold is
  the only intensity governor: no attempt-counted restart ladder (0018
  §11's rejection, kept, in the field's sharper unit) and no auto-retry at
  all — the next push is the retry. Every fence trip and every semantic
  failure produces exactly one receipt-deduped alert and a durable record;
  nothing stops silently and nothing retries silently. *Prevents:* the
  $100/hour failure mode; intensity tables metering the wrong resource;
  silent death and silent drain.
- **N8 — No new settlement vocabulary.** Every failure in §12 maps onto
  `Completed | Failed | Step_limit | Interrupted`, `Ambiguous` claims,
  pending decisions, exit 0/1/2/3/130, and fence `Held` (0018 L5's
  corollary extended to the resident). The new words this RFC does mint —
  the receipt vocabulary — are a closed sum (§5.1), never settlement
  kinds. *Prevents:* a parallel outcome language.
- **N9 — Credentials never co-reside across trust domains.** Ingress
  secret in mentatd; model key only in the run child (re-resolved
  child-side — 0018 L8, never argv, never env-inherited); GitHub write
  token only in the publisher, which reads no untrusted checkout; the run
  child holds **no** GitHub credential. The run child's tool-sandbox read
  roots never include the auth store, the charter directory, or any
  `secrets/` path — a review run can read the worktree and the standard
  carveouts, nothing that authenticates; charter validation refuses a
  layout that would place secrets under a read root. *Prevents:* the
  Actions secret-leak class; a reviewer that can publish; the
  read-only-sandbox-still-execs exfiltration chain (the PR itself is an
  exfil channel for anything readable).

## 2. The charter

One directory per charter under the owner's config home
(`~/.config/mentat/charters/<name>/`): `charter.json`, the prompt file,
the findings schema (RFC 0019 §2, unchanged), `ingress.id`, and
`secrets/` (0600: webhook HMAC key; read PAT; write PAT).

```json
{
  "charter": 1,
  "name": "pr-review",
  "enabled": true,
  "workspace": { "repo": "invariant/spice" },
  "trigger": [
    { "kind": "github_webhook",
      "events": ["pull_request.opened", "pull_request.synchronize",
                 "pull_request.reopened", "pull_request.ready_for_review"],
      "gate": { "base": ["main"], "drafts": false,
                "associations": ["OWNER", "MEMBER", "COLLABORATOR"] } },
    { "kind": "cli" }
  ],
  "run": {
    "mode": "review",
    "model": "claude-sonnet-4-6", "reasoning": "high",
    "max_steps": 60,
    "prompt": "prompt.md",
    "output_schema": "findings.schema.json"
  },
  "budget": { "per_run": { "wall_clock": "15m" },
              "per_charter": { "usd_per_day": 15.0, "runs_per_hour": 6 } },
  "publish": { "github": "review-threads" },
  "notify": { "on": ["failed", "parked", "fenced"],
              "command": ["~/.config/mentat/notify.sh"] },
  "suppress": { "clean_run": "silent" }
}
```

**Grants: one capability model, two surfaces, parity by law.** The
principle is that the unattended surface must never be more expressive
than the interactive one — every grant a charter can make, an owner can
make at a keyboard, so the authority audit is one audit. The charter
vocabulary is therefore derived from the capability model both surfaces
share, not from whatever the CLI happens to accept; where the model
grows a knob, both surfaces grow it together. Today the two coincide
exactly: every `run` field maps 1:1
onto an audited `mentat run start` flag (`bin/cli_run.ml:1085-1255`).
There is deliberately **no `tools:` field**, because there is no `--tools`
flag: tool selection is mode + config derived (`bin/cli_run.ml:1113-1117`),
and a charter-only grant axis would make the unattended surface more
expressive than the interactive one — the wrong direction, and a fork of
the tool-identity story. What a charter adds beyond the run vocabulary is
exactly: the trigger set, the per-charter budgets, the publish binding,
the notify/suppression contract, and retention knobs.

**The v1 grant envelope is closed at decode.** In a `"charter": 1` file
the write-capable knobs do not exist: no goal, no write grant, no tool
axis; `sandbox` admits exactly `"read-only"` (with `require_sandbox`
implied) and `permission_unattended` admits only `"deny"` or `"block"`;
both may be omitted — writing them is documentation, widening them is a
load error. C7 therefore holds at decode: a file that could
consent or write fails to load. Loosening is a charter schema bump gated
on the S4 `Integration` principal.

**Trust and lifecycle.** The file is the registration (crontab semantics):
the node re-reads and re-validates it at each admission — deliveries are
rare, a stat+parse is free — so there is no registry, no reload protocol,
no cache; `enabled` is a field the owner flips in the file. Unknown
fields, versions, and trigger kinds are load errors (the `error_unknown`
discipline); a group- or world-writable charter or secret file is refused
the way sshd refuses a loose key. A repository may ship a *proposal*
(`.mentat/charters/…`); `mentat charter add` copies it in after the owner
reads it — a proposal never activates by discovery (N2).

**Identity.** The charter digest is the ordered hash of the policy
closure — `charter.json`, the prompt file, and the output schema —
excluding `secrets/` and `ingress.id`; any edit to any of the three
re-stamps receipts and resets the fence windows. `charter add` mints the
ingress path id once into `ingress.id` (edit-stable: owner edits never
move the webhook URL) and mints the webhook secret if absent; a webhook
charter without `ingress.id` is refused at load with the hint to run
`charter add`. `remove` deletes the id; a re-`add` mints a fresh URL and
says so, since GitHub settings must follow. Receipts are retained for the
charter's life — they are the dedup horizon and the metering substrate;
retention knobs govern worktrees only, never receipts.

**Verbs** (rung-1 surface; `rotate-secret` arrives with rung 1b, where
the secret it rotates first matters):

```
mentat charter add PATH|DIR      # validate; mint ingress id + secret;
                                 # print the webhook URL for GitHub settings
mentat charter list              # names, digests, enabled, last disposition
mentat charter fire NAME --event FILE | --sweep [--key STRING]
mentat charter runs NAME         # dispositions: when, trigger, spend, session
mentat charter status [NAME]     # the N5 fold, rendered
mentat charter remove NAME
```

(The `mentat charter` verbs ride the agent binary deliberately: they are
config-file writes plus wire-client calls — owner-facing UX, nothing
resident — so "the agent only" refers to what the process *is*, not to
which binary carries the admin verbs for its neighbor.)

`fire` is load-bearing twice over: `--event` exercises receipt, dedup,
gate, fence, spawn, publish — the identical path — with no network, and
`--sweep` performs one open-PR listing with the read token and
synthesizes deliveries for heads without receipts (the same fold rung 1b
later runs at boot). A crontab line `*/5 * * * * mentat charter fire
pr-review --sweep` is therefore a complete, fenced, deduplicated,
publishing review charter with zero listener, zero tunnel, zero service
unit — rung 1 dogfoods on cron alone. `fire` runs the pipeline in the
invoking process itself — the charter machinery is one code path with
two invoking processes (the CLI and the node) — so a crontab line needs
no resident node at all. The per-event-identity `O_CREAT|O_EXCL` marker
(§3 step 1) is what serializes a CLI `fire` against a resident intake:
one winner runs, the loser reads `dup`. (This supersedes an earlier
draft's daemon-surface transport, which contradicted §3 step 1's own
cross-process design and would have made rung 1 depend on residency.)

## 3. Triggers

The typed sum, fixed now so every later arm rides the same pipeline
(receipt → gate → idempotency → fence → run → disposition → report).
Every arm must
define an **event identity** (feeding N4), a **payload fencing rule**
(C4), and a **default rate fence** where the charter names none — or it
does not exist:

- `github_webhook` — **funded.** Identity `(repo, pr, head_sha,
  action-class)` — semantic, never the delivery GUID, so a UI redelivery
  dedupes and a new push runs. Default rate fence where the charter names
  none: `runs_per_hour = 6`.
- `cli` — **funded.** `mentat charter fire NAME [--event FILE | --sweep]
  [--key STRING]`. A bare or `--key` fire carries identity
  `(digest, key)`, `key` defaulting to the fire instant — distinct runs
  per fire, and an explicit key exercises the dedup path, the test seam
  for N4 itself; a bare fire on an event-shaped charter (nothing to
  review) is refused with the hint to use `--event` or `--sweep`.
  `--event` and `--sweep` fires carry the identity of the delivery they
  decode or synthesize, so the canonical `--sweep` crontab dedupes
  exactly as the webhook path would. `--event` bytes are fenced exactly
  as a webhook body. Rate fence: none by default — the invoker is the
  owner's own scheduler.
- `schedule` — **designed, unfunded.** Identity `(digest, fire-instant)`;
  at-most-one-pending, no backfill; fresh isolated session per fire,
  always a receipt. Parses and is refused as unimplemented; lands with a
  consumer OS cron cannot serve (the crontab-less fleet node).
- `agent_message` — **named.** Lands as a durable queue entry over the
  existing wire; needs a sender, not machinery.
- `self_schedule` — **named**, lawful only inside the charter's fences: a
  self-scheduled wake spends the same budget as any other, so a runaway
  self-scheduler dies at the fence, not at a special governor.

**The trigger-to-run path** (funded slice):

1. The listener authenticates and receipts the delivery (N3), answers
   202. Receipt creation is a per-event-identity file created
   `O_CREAT|O_EXCL` — create-exclusion is the **cross-process**
   serialization point, so a CLI `fire` racing the resident intake
   collapses to one receipt and one loser reading `dup`. Everything after
   the receipt — gate, fences, spawn, reap, fold, publish, notify — runs
   on one node fiber, so fold actions are at-most-once-in-flight.
2. The node re-reads the charter, evaluates the gate, folds the fences
   over receipts (N5, §6). Refusals are receipt lines — silent except the
   once-per-window fence alert. The gate also refuses a delivery whose
   `head_sha` is no longer the PR's current head — closing stale-head
   replays and supersession races at one stroke.
3. It derives the run session id — `"c-" ^ H(digest, event-identity)`
   under domain `mentat.charter.run.v1` — and prepares the ephemeral
   checkout at `~/.local/state/mentat/charters/<name>/runs/<session-id>/`
   (that directory is the run's workspace root, so store, journal, and
   run log are discoverable from the receipt alone): in the slice, a
   per-run shallow fetch of `refs/pull/N/head` verified to contain the
   payload's `head_sha`, disposed with the worktree — no long-lived
   mirror to create, authenticate, prune, or gc (the charter-side mirror
   is the named optimization, priced when clone latency measurably
   bites). The head is checked out **as data — never built, never
   executed** (C3). **Git hardening, binding for every node git
   invocation:** `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`;
   `core.hooksPath` pinned to an empty directory and
   `protocol.file.allow=never` at checkout creation; never
   `--recurse-submodules`, never `git submodule` against the head; the
   read token supplied per-invocation through environment-scoped config —
   never argv (visible in `ps`), never embedded in a remote URL
   (persisted cleartext).
4. It spawns the run child: the shipped headless surface, `mentat run
   start --id c-… --cwd <run-dir> --title "charter/pr-review PR#312
   @9c41f2e" …` with argv built field-by-field from the validated charter
   in `--flag=value` form (never a shell, never pass-through), the prompt
   (rubric + fenced event context, with delimiter runs and per-field caps
   chosen so no payload text can escape its fence) on stdin, JSONL to a
   run log in the run directory. The child is spawned **detached** (own
   session via `setsid`, never under a daemon switch), re-resolves its
   model key from the auth store (0018 L8), and carries no GitHub
   credential (N9).
5. The child runs the sealed review contract and exits under the existing
   contract; the node reaps, reads the journal head (L5: the exit code is
   liveness; the head is truth), stamps usage and derived cost into the
   disposition receipt, and disposes per §5's fold.

**Origin: typed provenance, from day one.** The initiating turn admits as
**`Turn.Origin.Triggered of { charter : string; digest; key : string }`**
— a new arm, in the journal. The derivation is first-principles: the
journal is the sole durable truth (D16), a turn's origin is truth, and
recording a machine-admitted turn as `User` would put a falsehood in the
durable record with the truth exiled to side channels. The arm lands as
an **ordinary vocabulary change, with no version bump** (§11.6): one
codec serves journal and wire with strict unknown-tag rejection
(`lib/session/turn.ml:53-99`, `lib/protocol/wire.ml:10-15`), but the
wire is pre-deployment — its only speakers are in-tree clients shipped
in the same release artifact — so negotiation ceremony would protect no
one; the journal is pre-release data too, and §11.6 retires removed
arms hard rather than carrying them. The ripple is
enumerable (the codec arm, the exhaustive origin/input match in replay
validation, projections, corpus goldens — priced in §13); the
vocabulary, with §11.4's removals landing alongside, comes out net
*smaller*. Mechanically the child receives its provenance
over the spawn channel (`mentat run start --triggered
<charter>@<digest>:<key>`) and the engine mints the origin; provenance is
attribution, never authority — a hand-forged `--triggered` flag misleads
only its own journal, and decision authority is untouched (no non-human
ever resolves a decision, C7). The session title and receipt continue to
carry the human-readable form. The cheaper alternatives are recorded and
rejected: `Origin.User` (a falsehood in the durable record), and landing
the delivery as a queue entry to admit as `Origin.Queued` (the sealed
contract — mode, schema, posture — rides the `Prompt` command; a bare
queue entry admits under session defaults).

**Idempotency and supersession.** Three layers: the `O_EXCL` receipt
(above); the content-derived session id, whose duplicate spawn collides
loudly at create (`Already_exists` → protocol `Unavailable`, child
exit 1 — `lib/store/session.ml:122-128`, `bin/session_meta.ml:19-21`) and
is receipted `already_exists`, never alerted — whether the prior run is
live is read from its run fence (a non-blocking probe), never from the
create error; and C2's marker upsert at publication. Supersession is
decided by receipt, not by head: on a fresher head for a live run the
node writes the `superseded` receipt *before* signalling SIGINT, and
every fold action — publish, settle, alert — is suppressed for a
receipt-superseded run regardless of how its head settles (a
grace-expired SIGKILL corpse is left unsettled and unalerted); the
publisher additionally refuses when the ledger names a newer head for the
same PR. Latest-wins, the resident analog of Actions'
`cancel-in-progress`.

## 4. Ingress

**The listener.** `mentat.server` — the library, now linked and served by
the `mentatd` binary (§11.5) — gains one content-neutral route family,
the third pre-auth surface beside `handshake` and `health`:

```
POST /ingress/github/<ingress-id>
```

`ingress-id` is a random 128-bit path component (the same entropy class
as the wire token, `mentat_server.mli:40-42`) — a capability URL as
second factor, not the authenticator. The family does exactly one thing:
verify `X-Hub-Signature-256` — HMAC-SHA256 over the raw body via
**digestif**, compared constant-time via **eqaf** (both already in the
lock; new `libraries` lines in `lib/server/dune`, no new package) — and
hand the verified bytes to the node's callback (resolving the path id by
scanning charter directories — O(charters), and deliveries are rare).
The addition keeps `mentat.server`'s boundary invariant intact: it still
links protocol, client, transport, eio — never an engine, a store, or a
provider transport. Absent header,
undecodable hex, or mismatch ⇒ the same content-free 401, counted, never
alerted per-event (an internet-facing endpoint gets garbage, and garbage
is not news); the SHA-1 `X-Hub-Signature` is never consulted. Body
capped (1 MiB — policy: observed `pull_request` payloads are ≤ ~100 KiB);
500, never 202, when the receipt cannot be written (N3); 202 immediately
after the receipt, before any gate work (GitHub's 10 s timeout). A
delivery for a disabled charter verifies against the retained secret and
receipts `skipped(disabled)` — disable is owner intent, not hook failure;
a removed charter's id resolves to nothing: content-free 404. No cookie,
no bearer, no Origin logic: the web mount's auth model is exactly wrong
for webhooks and is not reused. The wire's endpoint table is untouched
and **never binds public** — a delivery is not a command, GitHub is not
`Local_user`, and stamping it so would forge `answered_by` (0019 §5); the
wire token is an RCE grant, and OpenClaw's 40k exposed gateways is what
fusing those surfaces looks like at scale. With that ruled, the
always-raising `Bind.public` constructor is **deleted** (§11.5), taking
the server library's dead `tls`/`tls-eio` dependency edges with it (TLS
itself stays in the tree — the provider transport's outbound HTTPS
already carries it, and §7's in-process poster rides that same stack).

**Reachability.** The node binds loopback; the owner points any tunnel
they already trust at it (cloudflared, tailscale funnel, an nginx they
run, `gh webhook forward` for development). Because every delivery is
end-to-end authenticated by the HMAC, the tunnel is untrusted transport
by construction — where the packets entered is irrelevant to trust (RFC
0017 §7 already refuses "loopback ⇒ trusted"); a tunnel that re-encodes
the body breaks the signature *closed* (401, and the sweep covers).
Rejected for the slice: a first-party public TLS listener (certificate
lifecycle to receive one kind of signed POST); a hosted relay
(fleet-side, §10). Named future: a public bind *for this listener only*,
through the same closed-constructor discipline, when a proxyless
VPS-resident node becomes a real consumer.

**Recovery is observation, not redelivery.** The reconcile sweep — one
conditional open-PR listing per webhook charter, minting synthetic
deliveries for heads with no receipt — runs at node boot, after every
reap, and, while any webhook charter is enabled, on a node-side period
(policy, default 10 minutes). GitHub is the system of record for "what
needs review"; webhooks are a latency optimization over the sweep (C2's
reconcile-by-observe, generalized from egress to ingress), and the
degraded mode's staleness *is* the sweep period. This is the one clock
the node owns; N1 is untouched — the engine still only ever sees a
submit.

## 5. The node

The node — the charter-owning core of the **`mentatd`** process, one per
owner per machine, addressed by `mentatd status|install|…` — is
workspace-blind: no charter, receipt, or run root ever enters the
workspace registry mentatd also hosts for the attach surfaces (§11.5).
It is
deterministic code, not a model (**the charter is the crontab; the node
is cron**), owning the ingress callback, gates, fence folds, checkout
provisioning, spawn/reap, the receipt log, the sweep, the notify hook —
and, as the new home of the server composition, the attachment surfaces
`mentat serve` carried until now (§11.5) — with no durable state of its
own (N5). It executes runs by spawning the `mentat` binary through its
public front door; it has no private path into the engine.

**5.1 The receipt log.** One append-only JSONL file per charter,
`~/.local/state/mentat/charters/<name>/receipts.jsonl` (plus the
per-event-identity `O_EXCL` marker files of §3's step 1 — the markers are
the serialization point, the JSONL is the authoritative record; open
question 4's goldens pin both), written only by the node, never
rewritten. A line is one of four kinds — a closed sum with
`error_unknown` decode and a diagnostic projection (house norm):

- **delivery** — event identity, charter digest, received-at; the N3/N4
  serialization record;
- **disposition** — closed set: `spawned | skipped of reason | dup |
  fenced of meter | already_exists | superseded | refused of reason |
  reaped of {exit; head_outcome; usage; usd; cause}` — wall-clock expiry
  is `reaped` with cause `wall_clock`; a dead child settled honestly is
  `reaped` with cause `recovered`;
- **egress** — marker state after the C2 upsert;
- **alert** — the once-per-window / once-per-transition dedup record; N7
  rides this line, not memory.

`notify.on` and `suppress` name members of the **alert** kind's closed
transition vocabulary — v1 exactly `failed | parked | fenced`, N6's
alertable moments, derived by the fold from dispositions and journal
heads — and no other strings; `suppress.clean_run` governs the one
non-alert moment (§7). Where §12's "carried by" column names a receipt,
it names these four kinds; where no receipt exists it names the durable
input that does carry the fact (a journal head, a counter, an HTTP
status). Exact byte schema and goldens are implementation (open
question 4).

**The reconcile fold** — run at boot and after every reap; pure over
durable inputs, so running it twice is running it once. Child liveness is
read from the run fence (non-blocking probe of `sessions/<id>/run.lock` —
`Held` names the owner to signal; fences release on owner death, D17),
never from a stored pid; on boot each
live run's wall-clock deadline re-arms from its spawn receipt's
timestamp.

| Journal head | Egress receipt | Action |
|---|---|---|
| ingress receipt, no run journal, no live child | — | spawn (idempotent: N4 turns a lost race into a loud collision) — reachable because N3 promises work before spawning it, and the sweep cannot see it (the head has a receipt) |
| settled, findings | present | done |
| settled, findings | absent | spawn publisher (safe under C2's upsert) |
| settled, semantic failure | absent | advisory + alert, once per `(pr, head)` |
| unsettled, pending decision | — | **parked**: the child stays alive, serving its session, until the park TTL; alert names the session; the owner attaches from the session list and answers as `Local_user`; a parked child that died re-materializes on the owner's attach (free fence → successor binds; the decision fact is durable) |
| unsettled, no pending decision, child alive | — | leave it (the deadline ladder is armed) |
| unsettled, no pending decision, child dead | — | the broker re-materializes a successor once (0018 §7.3–7.4): its own `recover` drives the head to an honest settle — a provider-claim crash settles `Interrupted` at once; a tool-claim crash continues the turn to its natural settle, spending against the charter's fences — then the fold re-enters on the settled head (which may publish). One re-materialization per receipt; a successor that dies leaves the row for the next pass; the next push remains the retry |

(Re-materialization is recovery, not retry — `recover` never re-runs
settled work, so D1 is intact; and because every run child serves its
session (§9), the settling successor is the broker's ordinary duty, not
a special verb.)

**Parked runs, end to end.** A parked run holds a durable
`Decision_requested` fact at an **unsettled** head, and its child stays
alive, serving — an ordinary attachable session. The alert names the
session; the owner opens it from the TUI session list (or the §8
dashboard), reads the question in place, and answers as a true
`Local_user` through the ordinary decision surface — `answered_by`
records exactly who consented. At the park TTL the node interrupts the
child (exit 130, disposition `reaped(park_expired)`); the decision fact
survives in the journal either way, and the run directory is exempt from
retention until the decision resolves or the charter is removed. Under
`permission_unattended = deny` only permission asks auto-deny; a
`Question`/`Plan` request still parks — by design, that is the one thing
a read-only reviewer may still need a human for.

**Eviction, bypassed rather than fought.** An instance that has ever
driven a session is resident until daemon shutdown — drivers are removed
only at engine shutdown, so the three-zeros sweep can never evict it
(`bin/daemon.ml:160-179`, `lib/agent/mentat_agent.ml:82-97, 1014-1024`).
mentatd therefore never drives a charter session in its own process and
never lets a run root enter the workspace registry; a charter between
wakes is *cold* — no fiber, no driver, no hub. The tempting one-flag
alternative — spawning with `--attach` (`bin/cli_run.ml:884-887`) —
parks the engine in mentatd: the model key enters the resident image,
crash isolation is lost, and every run pins an instance for the
process's life. The child-serve boot (§9) is how live-follow is bought
without that trade: the run serves its own session, and mentatd — or
the owner's TUI — attaches as a wire client.

**The crash story.** Nothing in-tree restarts a crashed resident;
revival is lazy on the next client, which a webhook never triggers. The
slice funds what RFC 0020 §10 made the acceptance bar: `mentatd
install` emits a launchd agent / systemd *user* unit running `mentatd`
— with `KillMode=process` / `AbandonProcessGroup=true` pinned, so
an orderly stop or restart never signals a mid-turn run child; children
always outlive the resident and the fold adopts them at the next boot.
The pre-auth `GET /health` is the liveness probe; `mentatd status`
renders the fold. No in-tree watchdog — liveness is the OS's job — and a
version-skewed resident stays a loud refusal, never an auto-restart
(`bin/daemon.ml:807-816`).

**Escalation destinations.** Process-lane events land on the notify hook
and `mentatd status`; semantic-lane outcomes land where the owner already
looks — the PR advisory (0019 §4's table, reused verbatim) plus the
notify hook; node events (N6) never reach a PR.

## 6. Budget fences

Three meters, two scopes, all enforcement outside the engine; zero
engine change.

- **Per-run.** Steps: `--max-steps` (exists; the natural bound for a
  diff-scoped review, whose wrap-up rides the goal-independent
  `Step_limit_wind_down`). Wall-clock: the node arms a deadline at spawn;
  expiry walks SIGINT → grace (0018 §5's shape) → SIGKILL; the receipt
  names `wall_clock`, and the SIGKILL branch is owned by §5's settle row.
  Tokens/currency per-run: deliberately unfenced mid-run — an admission
  fence cannot fire inside a single-turn run; steps × wall-clock bound
  the run, the charter fence bounds the month.
- **Per-charter.** At reap, the node reads the run's journal **once** and
  stamps spend into the disposition receipt: each assistant response
  carries its lane-structured `Response.usage` and its `Response.model`
  (`lib/session/state.ml:880-901`), folded through `Model.cost`
  (`lib/provider/model.mli:402-417`) and summed — the per-turn
  `usage_total` int is a token diagnostic, never the billing input; a
  model with no rate for a spent lane derives `None` and the charter
  degrades to the run-count fence, receipted as such. Before spawning,
  the node folds **receipts only** over trailing UTC windows (24 h /
  60 min — never calendar-day buckets, so no midnight burst and no DST
  edge): `usd_per_day` and `runs_per_hour`. Trip ⇒ delivery refused,
  receipt appended, one alert per window (the dedup *is* the tripped
  fence's window, recorded as an alert receipt); the window rolling or a
  charter edit (digest bump) re-admits. Run journals are opened on the
  admission path never — only the reconcile fold reads journal heads,
  and only for runs without a disposition receipt.
- **Named future — the in-engine session fence.** A pure predicate at the
  admission seam over a **session-total** usage read, in the shape the
  existing wind-down machinery proves
  (`lib/agent/step/mentat_agent_step.ml:2138-2149`,
  `lib/agent/driver.ml:614-628`); it lands with the first multi-turn
  charter. (It deliberately does not cite the goal budget as its vehicle:
  a goal's accounting sums only continuation turns —
  `lib/session/state.ml:544-551` — which is §11.4's evidence.)

## 7. The funded slice

The pipeline is §3's. Past the child's exit: findings document (0019 §2,
unchanged — no GitHub vocabulary in it, C6) → the node reaps, stamps the
disposition receipt, and reads the head → publisher subprocess (write
token, no model key, no checkout): 0020's pure renderer → review threads
+ summary upsert under the C2 marker → egress receipt → checkout reaped
(parked runs and the last N failed retained) → silence
(`suppress.clean_run` governs the empty-findings case; the summary still
upserts so stale threads self-correct).

**The publisher's transport, ruled by context.** RFC 0020's `gh`-piped
arithmetic ("two writes and three reads do not fund an HTTP client") was
computed for GitHub Actions, where `gh` is ambient — and it stands
*there*, which is rung 0's path. For the resident node it does not
carry: mentatd is a long-lived product whose only external runtime
dependency is `git`, confined to §3's hardened checkout provisioning —
and `gh`-as-a-second-runtime-dep is a per-install tax paid forever. The
node's publisher is therefore **first-party from the funded slice**: a
short-lived publisher child (spawned per publication, preserving N9's
isolation — the write token in a process that parses no attacker text
in the resident image) whose transport is the HTTPS client stack the
provider transport already vendors (no new dependency), with C2's
GET-match-upsert unchanged. `gh` remains the Actions-path transport
only.

**Reused verbatim:** the findings schema; laws C1–C8 wholesale; 0020's
renderer design (anchoring, convergence, neutralization,
publisher-derived verdict); the 0019 §4 advisory table; the entire
headless spine (session mint, sealed review contract, kernel sandbox,
deny-only unattended principal — `lib/session/decision.ml:303-311` —
schema retry + `run.output_schema_failed`, JSONL, exit codes); the run
fence and journal laws. **New** is §13's component list.

**Coexistence and migration with Actions Stage 1.** The C2 marker carries
an origin discriminator, minted from rung 0 (`origin=ci` by default,
`origin=actions` in the workflow, `origin=charter:<name>` here — an
0020 §2 amendment, §11.2), with two renderer obligations now that
findings text is attacker-derived: marker detection matches only a
complete marker line authored by the publishing identity (comment
delimiters in findings text are neutralized at decode, so an embedded
marker string is inert even to raw-text scans), and `@`-mentions in findings text are neutralized so a
prompt-injected review cannot page humans. A repo can run both publishers
during migration observably and without corruption — at double spend,
stated plainly. `charter add` detects `.github/workflows/*mentat*` and
prints the migration note; the sweep picks up anything the cutover gap
missed. Actions Stage 1 remains the right answer for repos whose owners
run no node.

**The read-only boundary, and the Integration future.** Nothing in this
slice can consent: the grant envelope refuses at decode (§2), unattended
may only deny in the engine, and the write token never coexists with
untrusted input (N9). When an S4 `Integration` principal lands (0019 §5;
0020 §10's `Principal.Github` constraints), the changes are additive: the
charter schema admits a consent clause behind a schema-version bump;
and parked decisions gain a connector-resolvable path bound to
`(repo, pr, head_sha)` with `answered_by` naming the true actor — the
observability a write-capable run demands is already there, since every
run serves its session (§9). This also settles the pending 0022
auto-review design's place: the charter envelope will never admit
`permission.unattended = review` — parked-but-durable, answered by a
human from the session list, is this
RFC's answer to the same moment — so 0022 is re-sequenced behind the
Integration principal (or abandoned with its fail-closed doctrine
harvested there), and one pending design leaves the near-term roadmap
(§13).

## 8. Outbound

Four surfaces, in order of authority: the **record** (receipts + run
journals; `charter runs`/`status`); the **PR** for semantic outcomes of
webhook runs (zero new transport); the **notify hook**; the **session
list** (run sessions are ordinary sessions, titled with outcome, visible
via `mentat sessions --all` and `charter runs` — each run's root is its
own directory, so no per-workspace listing carries them). There is
deliberately no new frontend product: the always-on layer's unit is the
run, not the conversation, so its oversight surface is a fold rendered
as a page — at rung 1b, mentatd's web mount gains one server-rendered
dashboard (the `charter status` fold with links: needs-attention first —
parked runs with their question and attach path — then charters with
spend-against-fence, then dispositions), while the chat surface stays
exactly what it is, ready to become the conversational face of charters
when `agent_message` lands.

The notify hook is **one shared firing module** — spawn argv best-effort,
output discarded, short timeout — consumed by the TUI (whose private
`notify_policy`/`notify_hook` copy in `bin/cli_tui.ml:359-412` it
replaces) and by the node, under one calling convention chosen for the
contract's own merits, not for continuity: **one JSON event on stdin**
(control-characters stripped), because a structured event deserves a
structured channel and stdin cannot collide with argv parsing. The TUI's
young `argv @ [title; body]` convention migrates to it in the same
change — one contract, two callers, no adapter. The
charter's `notify.on` vocabulary is deliberately charter-local — receipt
transitions, not `Notify.Event`'s TUI turn events — and the two never
merge: one names moments a watching user cares about, the other names
dispositions of unattended runs. `mentat run` completion gains the same
hook behind the existing config, command channel only. Rejected: channel
transports, digests, routing (no consumer); the durable
`Workspace_notice` outbound is a named future behind its own ruling
(§14).

## 9. RFC 0018: the local-child rung, in the funded slice

**Ruling 3, honored in full (ruled 2026-08-25).** Every charter run is
an OS process serving its own session from day 1 — **0018's child-serve
boot, in the slice**: a `mentat` process serving exactly one session
(its own), mentatd its connect client over the same wire everything
else speaks. The funded 0018 subset, per its §10's own staging: the
`Child_backend` seam with `In_process` wired (the pure refactor,
golden-gated); the local-child rung's session-serve boot; session-keyed
registration with endpoints derived from the session id; the broker's
spawn/observe/reap duties with fiber-native reaping and
re-materialization; orphan rediscovery on restart; and §7.4's fence
rule (`` `Held`` ⇒ bind-as-observer, never the in-process `` `Held`` →
`Busy` arm). The broker — "the daemon's" in 0018's vocabulary — is
mentatd's under this RFC's cut. 0018's laws bind as before: L5, L6, L8
(identity over the spawn channel; credentials re-resolve child-side;
prompt over stdin, never argv), L9.

**Why child-serve and not run-and-exit — the shape argument.** An
earlier draft spawned the headless surface fire-and-collect, honoring
"OS processes" while deferring 0018's machinery. That shape is rejected
(§15.7) because its costs surfaced as special cases: a dead child's
unsettled head needed an invented `mentat run settle` verb (no
prompt-less attach exists — `run resume` requires a PROMPT and mints a
turn, `bin/cli_run.ml:1416-1423`), a parked run needed a bespoke
attach-from-this-directory dance, and charter runs became the only
sessions in the system that could not be attached while running. Under
child-serve all three dissolve into the broker's ordinary duties:
re-materialization settles dead children, a parked run is an attachable
session answered from the session list, and live-follow is the wire
doing its job. What the slice still does not need: the delegation
specialization codec (a charter run is a root session), the warm pool
(N=0 stands — a spawn-per-event workload at minutes scale generates no
pool consumer), the remote rung.

**Charter runs are root sessions, not delegation children** — no
delegation edge is minted, so all six turn-anchored delegation sites stay
byte-unchanged by not being used; a charter run that spawns subagents
uses 0018 verbatim from its own turns. L1 generalizes to N5: the node is
a function of the run journals and the receipts.

## 10. Fleet-facing constraints — invariants and named futures only

- **Node verbs are a node-global row family** beside `handshake`/
  `health`/`ingress` on mentatd's wire — never rows on the
  workspace-scoped `Driver.t` cones — preserving the
  one-descriptor-table symmetry. Built now: `mentatd install|status`
  (CLI). Named: wire `node.status`, `node.drain`, `node.reload`.
- **Metering is always re-derivable.** Receipts are the substrate,
  carrying at minimum charter, digest, delivery, session, usage, derived
  cost, disposition; a future `node.meter` row is a fold over them;
  mentat never grows a billing database.
- **Provisioning is files plus a verb.** A node is fully provisioned by
  writing files — charters, 0600 secrets, the auth store — plus restart
  or `node.reload`. No secret ever crosses the wire; no wire codec that
  could carry one may exist.
- **The relay is transport, never authority.** The node dials **out** to
  the fleet relay and holds the connection; the relay forwards deliveries
  byte-exact — or signatures break; that byte-exactness is the entire
  handshake contract — and adds its own transport auth outside the
  signature. The node verifies GitHub's HMAC itself, end-to-end; relay
  outage degrades to the sweep: latency lost, correctness kept.
- **The node's GitHub base URL comes from validated configuration, never
  ambient environment**: an env-writable API base redirects Bearer-token
  requests, so the CLI publisher's `MENTAT_GITHUB_BASE_URL` seam (a test
  and GHES override for an owner-run command) must not be inherited by
  mentatd.

## 11. Amendments ledger

**11.1 RFC 0000 S3.** S3's four maintained invariants stand verbatim,
each load-bearing here: external service effects never enter the mutation
ledger (0019's C1 → receipts); review publication is separate from review
state (→ the publisher subprocess); D1's reconciliation-oracle clause
(→ the lane law and the sweep); tool identity and decision authority
cannot be widened by external text (0019's C4 → the fencing rules). The
closing sentence — "V1 builds no trigger, inbox, or intent machinery" —
is replaced:

> RFC 0024 builds the trigger layer: typed triggers defined by
> owner-written **charters** (configuration, never workspace content) and
> interpreted by a resident **node** at the composition root, with an
> authenticated webhook **ingress** on the daemon edge (GitHub first;
> schedules designed in the same taxonomy). **No new inbox machinery
> enters the engine**: agent-to-charter messages land on the existing
> durable session queue; webhook deliveries never enter any journal —
> they are receipted at the connector edge in the node's append-only
> receipt log, the one durable record the resident layer adds, and
> everything else is derived by folding run journals and observing the
> external system. Intent machinery remains rejected: no durable work
> items, attempts, retry tables, or meters. Settlement vocabulary is
> unchanged. Origins change exactly once: `Turn.Origin.Triggered` —
> typed trigger provenance, attribution never authority — enters at
> the pre-deployment vocabulary (RFC 0024 §11.6, no version bump), and
> `Origin.Goal_continuation` leaves with the goal vocabulary
> (RFC 0024 §11.4), retired hard: a pre-release journal carrying goal
> facts stops loading with a loud decode error. Charters cannot widen
> grants beyond the read-only envelope until S4's `Integration`
> principal exists.

RFC 0019 C8's forward reference ("…until the daemon owns that question
(S3)") is discharged exactly so.

**11.2 RFC 0020.** Superseded in §10: "polling, not webhooks" — ruling 2
funds the resident webhook; polling survives demoted to the reconcile
sweep, where it is observation, not triggering. Discharged in §9: the
final deferral row parking §10 behind its named triggers — ruling 2 is
that trigger, and this RFC is the written design it required; the
availability-regression acceptance bar (autostart unit + liveness signal)
is *funded* here, not pending. Adopted as binding from §10: never the
live tree; connector-owned 0600 credentials, never `auth.json`; PAT-only
identity (App identity stays paired with the relay future); no durable
intent beyond inputs; the `Principal.Github` constraints. Amended in §2:
the C2 marker carries the origin discriminator from rung 0 — minted by the
renderer's `--origin` flag — with §7's two neutralization obligations.
Companion rescopes in RFC 0019: WATCH 2 becomes
Actions-only (on the resident path, exit 3 is a designed outcome —
parked, durable, alerted, answerable); WATCH 3's wall-clock deadline is
node-owned for resident runs.

**11.3 S4.** Realized, not amended: the ingress authenticates deliveries
and resolves no decision; no new principal arrives with this RFC.

**11.4 Goals — superseded (ruled 2026-08-25).** Charters
supersede goals as mentat's autonomy surface, and the goal machinery —
≈2,700 impl + ≈2,400 test LOC across the library, state fold, origin arm,
four protocol commands, three errors, a journal fact, the `update_goal`
tool, the TUI screen, and the CLI surface — becomes deletable. The
evidence: the goal budget meters the wrong denominator for its own use
case (`tokens_used` sums only `Goal_continuation` turns —
`lib/session/state.ml:544-551` — so a `--goal --goal-budget` run that
completes in its first turn is fenced by nothing), and the in-session
self-prompting loop is the pattern this campaign rejected at charter
scope (§15.1; §15.5 is the same rejection at session scope), surviving
only on the attended-session defense. **RULED (2026-08-25): deleted.**
The maintainer's test — "why would we not delete it?" — found no
survivor: the one genuine loss, attended in-session multi-turn
self-continuation, has partial substitutes in the durable queue, the
todo board, and plan mode, and does not justify carrying two budget
vocabularies of which the in-engine one is mis-denominated. The
deletion is a design decision, not an empirical one, so it is not gated
on dogfood: behavior and vocabulary go **with the slice** — the
admission arm, accounting, `update_goal`, the screen, the flags,
`continuation_turn_limit`, the four `Goal_*` commands, the
`Prompt.goal` payload, `Journal_goal`, the errors, and
`Origin.Goal_continuation` — retired **hard, with no tombstones**:
the tags join the tree's retired-vocabulary list as deliberate decode
errors, so a journal carrying goal facts stops loading loudly. The data
at stake is pre-release only, and the retirement discipline's
simplicity — every retired tag is a hard decode error, no
half-vocabulary lingers — outweighs replayability of superseded
pre-release sessions (§11.6 re-scopes the zero-data-loss gate
accordingly). Requires amending RFC 0000 **D10** and D11's "wins over
goal continuation" clause, carried by this RFC. `Step_limit_wind_down`
is not goal machinery and stays.

**11.5 RFC 0017 — residency moves to `mentatd`.** Two amendments. (a)
**The daemon composition changes owners, not shape.** `mentat serve` and
its `bin/daemon.ml` composition — discovery, claim, registry, wire
serving, web mount — move to the new `mentatd` binary; `mentat` sheds
the subcommand and with it every resident concern, becoming the agent
only (TUI + `run`, in-process). The `mentat.server` and `mentat.client`
libraries are untouched — the same code, linked by a different
composition root — and RFC 0017's laws (the boundary invariant, the
descriptor-table symmetry, one-driver-per-session) carry over verbatim.
`--attach` now discovers-or-spawns mentatd; 0017's deferred Stage-3
question ("the daemon as standard interactive runtime") becomes
"mentatd as standard runtime," still deferred, still 0017's to schedule.
The two binaries ship in one release artifact and mentatd spawns runs
from the `mentat` beside it, which is what keeps version skew a refusal
corner rather than a routine hazard. (b) **The `Bind.public` constructor,
its `Unsupported` exception, and the listen/connect refusal arms are
deleted** (~60 LOC; no caller constructs it, no consumer catches it):
this RFC rules the wire never binds public, and RFC 0000's own law says
reserving constructors under strict decode is incoherent — version
negotiation is the mechanism. The closed-constructor *discipline* is
retained for the named listener-only public bind. Dependency
consequence: `tls`/`tls-eio` leave `lib/server/dune` (dead edges — the
provider transport keeps TLS in the tree for outbound HTTPS, which §7's
in-process poster rides); `digestif`/`eqaf` enter as direct ingress
deps.

**11.6 Wire and journal vocabulary — no version bump (ruled
2026-08-25).** The version integer stays at 1. Version negotiation
exists to protect deployed readers, and there are none: the wire is
pre-deployment, its only speakers are in-tree clients shipped in the
same release artifact — bumping would be ceremony protecting no one.
`Turn.Origin.Triggered` enters and the goal vocabulary (§11.4) leaves
as ordinary vocabulary changes, net smaller. The **journal on disk** is
pre-release data under the same reasoning: the removed arms are
retired **hard** — the tags become deliberate decode errors, exactly
the treatment every previously retired tag already receives — and a
journal carrying goal facts stops loading with a loud error rather
than replaying through carried tombstones. Phase 1's zero-data-loss
gate is re-scoped to post-release journals; superseded pre-release
sessions are not worth a second, decode-only vocabulary. The handshake
floor (`mentat_server.mli:299-301`) stays as built, unexercised until
a deployed reader exists to protect.

## 12. Failure semantics

No row needed a new settlement word, principal, or durable supervisor
store (N8); the one new origin arm (`Triggered`, §3) is provenance, not
an outcome. "Receipt" refers to §5.1's closed vocabulary.

| Failure | Carried by | Owner sees | Recovery | Lane |
|---|---|---|---|---|
| non-event: duplicate/replayed delivery, gate skip, superseded head | receipt `dup`/`skipped`/`superseded` | status counters | drop (a superseded live run is SIGINTed; the new head runs) | node event (quiet extreme: receipt and counters, no alert) |
| forged delivery (HMAC fail/absent/malformed) | throttled counter | threshold alert | 401; `rotate-secret` (rung 1b) | node event |
| receipt present, run never spawned (died pre-spawn) | delivery receipt, no journal | usually nothing | the fold's first row spawns it | process |
| child dies mid-turn | unsettled head, no pending decision | alert `failed` after settle | broker re-materializes once → honest head → fold disposes; next push retries | process |
| node down (daemon crash; deliveries missed) | absent receipts | reviews late | OS unit restarts; fold adopts surviving children; sweep synthesizes missed deliveries | process |
| wall-clock expiry | `reaped(wall_clock)`; head `Interrupted` or settled by the settle verb | advisory + alert | never auto-retried | semantic |
| schema exhaustion | `run.output_schema_failed`, exit 1 | advisory naming it | never re-retried | semantic |
| parked decision | exit 3; unsettled head, durable pending decision | advisory + alert with the run directory | owner attaches from that directory, answers as `Local_user` | semantic |
| currency/rate fence trip | receipt `fenced(meter)` | one alert per window | window rolls or owner edits (digest bump) | node event |
| read/write token dead or revoked (401/403 at fetch, sweep, or publish) | receipt `refused(credential:<file>)` | one alert naming the token file, per window | owner replaces the 0600 file; next delivery or sweep proceeds | process |
| publisher crash | egress receipt absent | late threads | re-publish (C2 upsert is safe); exhaustion → alert, re-runnable by hand | process |
| prompt injection via PR text | findings content | odd review text | contained by construction: contract sealed pre-text; no write credential near untrusted text; §7's marker/mention neutralization; verdict publisher-derived | semantic |
| charter invalid at wake (bad file, loose perms, missing credential, model not ready) | receipt `refused(reason)`, no session | alert | owner fixes; digest bump resets windows | node event |
| receipt unwritable (disk) | 5xx pre-202 | GitHub delivery log + alert | node refuses admission until writable | process |
| daemon/child version skew | receipt `refused(version_skew)` | "restart the node" | loud refusal, never auto-restart | process |

## 13. Cost, deletions, metric, kill

**Build** (recomputed against the repo's measured density — `cli_run.ml`
is 1,971 lines for one CLI family, the config codec ~2,700): ingress
family ~300; charter decode/validation ~500 (an executable-private module
with an `.mli`; promotion to `mentat.charter` named at the second
consumer); node ~1,200–1,750 (payload decode + gates, checkout
provisioning, spawn/reap/deadline/supersession, receipts + folds + lane
classification, sweep, notify); CLI cones ~500–750; service-unit emitter
~120; the in-process publisher ~200–300 (renderer bodies over the
provider transport's HTTPS stack; C2 upsert); the `mentatd` binary
split ~150–250 (a second composition root over the same libraries,
build stanzas, the `serve`→`mentatd` migration shim); the vocabulary
change ~300–400 (the `Triggered` codec arm, replay-validation arms,
projections, corpus goldens); the
0018 local-child subset ~1,200–2,000 (the `Child_backend` seam,
session-serve boot, broker spawn/observe/reap with re-materialization,
session-keyed registration, orphan rediscovery — §9; this serializes
the slice behind 0018's first two rungs, accepted knowingly).
**In-slice ≈ 4,500–6,400 LOC.** Required before dogfood but shared with
the Actions path (rung 0): the 0019 §2 findings document (~200) and the
0020 renderer (~400–800), both zero code today; plus tests per house
norm (~600–1,000: receipt/fold/gate byte goldens, decode-refusal
goldens, HMAC vectors, an end-to-end `fire` cram). **Path to first
dogfood ≈ 5,700–8,400 LOC.**

**Deletions** (the simplification ledger; survey-verified anchors):

| Deletion | Surface | When |
|---|---|---|
| Goal machinery (§11.4, **ruled deleted**) | ≈ −2,700 impl, −2,400 test; −4 protocol commands, −3 errors, −1 journal fact arm, −1 origin arm, −1 TUI screen, −1 tool, −2 CLI flags, −4 reply verbs, −1 config knob (+ its planned expansion, `bin/composition.ml:1783-1791`); no tombstones (hard retire) | with the slice |
| `mentat serve` as an agent subcommand (§11.5) | the agent binary sheds all residency; the composition moves, not grows | rung 1 |
| `Bind.public` + `Unsupported` (§11.5) | ≈ −60 LOC; −2 dead dune deps from `lib/server` | in the funded slice |
| The rung-0 renderer pair's duplicated `Error` module and positive-int decode guard (`bin/review_finding.ml` / `bin/publication.ml`) | ≈ −25 LOC, merged when the pair moves to its shared `bin/connector` home for the in-process publisher | rung 1 |
| `gh` as a resident runtime dep | never incurred — the publisher posts over the vendored HTTPS stack (§7); `gh` stays Actions-only (`git` remains, confined to §3's hardened checkout provisioning) | by construction |
| RFC 0022 (auto-review) de-funded (§7) | −651-line pending design; ~1,000 LOC never built | now |
| TUI-private notify firing (§8) | ≈ −40 (one shared module; prevents a divergent second copy) | rung 1 |
| Roadmap ladder rungs 3–5 → one design; goal doc surface | ≈ −50 prose; two future design campaigns collapsed into charter trigger arms | on landing |
| Avoided outright | the ~300-LOC headless-band re-hosting (the node spawns `run start`); an in-node scheduler; a delivery/intent store; a second structured parser | by construction |
| The `In_process` delegation arm (deletion candidate, amends 0018's compatibility clause) | the seam's second backend and its cross-backend golden upkeep; deleting it makes every subagent an OS process and delegation one story | after the broker lands and soaks: `In_process` re-justifies against its true rents (unit-tier delegation tests; the one-shot CLI's teardown policy) or goes. The soak clock cannot start while `Brokered` still leans on the arm: post-first-turn delivery attaches in-process drivers, a brokered child's own grandchildren run in-process inside the child server (depth ≥ 2 brokering is 0018 §7.2's named RPC, unbuilt), and the one-shot CLI's die-with-the-run teardown has no brokered substitute without a resident reaper. Until the seam's delivery verb and the daemon's session-keyed child routing land, the arm is infrastructure, not a candidate |

**The honest net:** the tree grows in the slice — ≈ **+1,700 to +3,600
impl** (4,500–6,400 built against ≈2,800 deleted: goals −2,700,
`Bind.public` −60, notify dedup −40) — while tests shrink
≈ **−1,400 to −1,800** (600–1,000 added against
−2,400) and the wire loses four commands net. What shrinks is
*surface*, not line count: an agent binary with no daemon, a
net-smaller wire vocabulary, one origin arm swapped for a truthful one,
one fewer pending RFC (0022: −651 design lines, ~1,000 LOC never
built), no bespoke settle verb or parked-attach dance (dissolved by
§9's child-serve), and two future design campaigns collapsed into
trigger arms — against one new security surface (the listener: one
route, one verb, one header, zero content), one new durable schema
(charter v1), one new receipt format, a second binary in the release
artifact, and nine new CLI verbs across rungs 1–1b (six `charter`, two
`mentatd`, `rotate-secret`).

**Ongoing.** Mentat-side, the standing costs are the listener itself,
GitHub event-vocabulary drift in the gate, and run-directory disk
lifecycle bounded by retention. **Owner-side** (against the Actions
baseline of one workflow file + two repo secrets): rung 1 = a crontab line, two PATs, no tunnel,
no unit, no HMAC. Rung 1b adds a tunnel with a stable URL, the OS unit
(reinstalled on binary upgrade), the webhook secret, and the GitHub
webhook config that must track the tunnel URL. The resident path is for
the owner who already operates infrastructure — a tailnet, a VPS, an org
policy against repo secrets or paid runners — and reviews enough PRs for
latency to compound; for a public solo repo, Actions Stage 1 dominates
and this RFC does not pretend otherwise.

**Success metric:** mentat's own PRs reviewed by a charter on a
maintainer's node for 30 days — zero duplicate publications, zero silent
losses (every push has a receipt or a sweep record), spend within the
declared fence; and for the webhook path specifically, p50
push-to-review-start under 30 seconds, measured against one control week
running the same charter on a 5-minute cron sweep.

**Kill criteria, split by what each rung uniquely provides.** The
*listener* (rung 1b) lives or dies on latency and delivery integrity
alone: if after 30 days its p50 push-to-review-start is not at least 5×
better than the control week's cron sweep, or it loses deliveries the
sweep would have caught, retire the ingress family and keep the sweep as
the trigger. The *charter/node layer* (rung 1) is judged on custody and
discipline: if owners will not run a node even in cron form, retire the
node and keep charters as validated configuration for the Actions path.
The charter vocabulary, receipts, and fences survive either verdict.

## 14. Staging

0. **Rung 0 (prerequisite — ruled 2026-08-25, both paths):** the 0019
   §2 findings document, the 0020 renderer, the `run review` /
   `github review` commands, the Actions workflow, and the recipe page
   (`doc/manual/github-review.md`) land together, and mentat's own PRs
   are dogfooded via the workflow. **Both GitHub paths are supported
   product surfaces** — the precedent is the field's own (OpenAI ships
   the codex-action CI path *and* hosted App-based review): the
   workflow serves CI-path repos at the cost of a model key in repo
   secrets, stated plainly; mentatd (rung 1b) is the resident path that
   removes that concession; the hosted App belongs to the fleet, paired
   with the relay (§10). The commands are the shared substrate of all
   three — the workflow and the recipe are glue over `run review` and
   `github review`, and mentatd's publisher wraps the same renderer
   core. Review *quality* is proven here before any resident machinery
   is funded.
1. **Rung 1 (the funded slice's cron-complete waypoint):** the `mentatd`
   binary (the server composition re-homed; `mentat` sheds `serve`) +
   the 0018 local-child subset (§9 — every run serves its session) +
   the vocabulary change (`Origin.Triggered` in, goals retired hard;
   §11.6) + charter vocabulary + `fire --event|--sweep` + receipts +
   fences + notify + the first-party publisher + the `Bind.public`
   deletion. A crontab line is a complete, fenced, deduplicated,
   publishing review charter — dogfoodable with zero listener, every
   run attachable from the session list.
2. **Rung 1b (completes the funded slice — ruling 2 is webhook-reactive
   review, which needs the listener):** the ingress family + tunnel docs
   + periodic sweep + `mentatd install` + `rotate-secret` + the §8
   dashboard page. The webhook goes live; the sweep demotes to recovery.
3. **Named futures, each behind a consumer or a ruling:** the in-node
   `schedule` arm (the crontab-less fleet node); the in-engine
   session-total fence (the first multi-turn charter); the public ingress
   bind (the proxyless VPS node); `Workspace_notice` outbound (its own
   ruling); the relay handshake and wire node verbs (the fleet);
   `agent_message` (a sender); `self_schedule` (a ruling + a consumer);
   the charter-side mirror (measured clone latency); the Integration
   principal (RFC 0019 Stage 3); multi-forge (promotes the connector to a
   library per 0019).

## 15. What this RFC rejects, with reasons

1. **The standing charter session** — one resident model-driven session
   per charter, deliveries on its queue, runs as its children. Recovery
   must be a fold, not a model's inference; it adds a rumination surface
   at the point whose job is bounding rumination; one wedged session
   blocks every delivery; its journal is hot and unbounded; cross-PR
   attacker text accumulates in one window (C4); and a driven daemon-side
   session pins its instance until daemon death. Its one real insight —
   standing records — survives as receipts. It returns, named, as a
   possible shape for *conversational* charters behind `agent_message`.
2. **The node as a pure wire client of a still-resident `mentat serve`**
   (two resident processes: the agent keeps its daemon, and a separate
   orchestrator drives it over RFC 0017). Doubles the resident-process
   problem (autostart, liveness, credential custody ×2) for a boundary
   between two components the same owner trusts equally, and cannot
   reach the disposal and fence seams it needs. The corrected cut
   dissolves it: there is exactly one resident (`mentatd`), it owns
   *all* residency including what `serve` carried, and the agent has
   none — engine-blindness is kept by construction, since mentatd only
   ever execs `mentat` through its public front door.
2b. **The node inside the agent's binary** — `mentat serve` growing the
   charter layer, mentatd deferred as a "named extraction." This was the
   draft's own shape and it is rejected here with its history recorded:
   it was argued from distance-to-HEAD (the daemon already exists in the
   `mentat` binary), not from the right decomposition, and it quietly
   contradicts the product truth that an agent needs no residency. The
   one real asset of the one-binary shape — node/runner version-lock —
   survives the split via the single release artifact (§11.5).
2c. **Run-and-exit charter runs** (spawn the headless surface
   fire-and-collect; consume 0018's laws but not its machinery). An
   earlier draft's shape, rejected because its costs surfaced as
   special cases (§9): an invented settle verb for unaddressable dead
   children, a bespoke attach dance for parked runs, and charter runs
   as the only sessions in the system that could not be attached while
   running — the no-special-cases test failing three ways. Its one
   asset — less 0018 surface in the slice — was scheduling, not design.
3. **Charters compiled to the OS** — `charter add` emits a
   socket-activated unit per delivery, cron for schedules, no resident
   node. Supersession needs a resident view of live runs; the sweep needs
   a home; two OS unit vocabularies become product surface; and the fleet
   needs an addressable node — a pile of units has no `drain`. What it
   gets right, the design keeps: rung 1 runs on cron alone, and the OS
   unit survives as the daemon's own liveness answer.
4. **A frontmatter-markdown single-file charter** (body = prompt). The
   house idiom for prompt-bearing files, but the nested
   grant/budget/gate structure exceeds the flat frontmatter idiom and
   would fund a second structured parser for no consumer. The prompt
   stays a sibling file.
5. **The in-session goal loop as the unattended-autonomy vehicle.** The
   rejected standing-session pattern at session scope — after every clean
   settle the engine re-prompts the model with its own objective until a
   turn-count knob or a budget that meters the wrong denominator stops
   it. Attended sessions keep a human watching; unattended autonomy gets
   fresh fenced runs over durable state instead. This rejection is
   §11.4's motivation.
6. **A durable delivery queue / intent store / meter table.** Every
   candidate is derivable from receipts + journals + the observable
   external system; persisting one recreates the drift class Method
   rule 2 kills — and S3's "no intent machinery" survives amendment
   because of it.

## Rulings and open questions

**Ruled 2026-08-25 (formerly blocking):**
1. **Charter runs serve their sessions — the 0018 local-child rung is in
   the funded slice** (§9). The run-and-exit tempering is rejected with
   its reasons recorded (§15.2c); the cost and the serialization behind
   0018's first two rungs are accepted knowingly (§13).
2. **Goals are deleted** (§11.4) — with the slice, not gated on dogfood;
   retired hard, no tombstones: a goal-bearing journal stops loading
   with a loud decode error.
3. **No protocol version bump** (§11.6) — the wire is pre-deployment;
   the vocabulary changes land in v1; the journal is pre-release data
   and retires the removed arms hard.

**During implementation:**
4. The receipt byte schema and its `status` fold — byte goldens per house
   norm (§5.1 fixes the state space; the bytes are implementation).
5. Gate vocabulary v1: which GitHub event fields are load-bearing
   (`association` semantics for forks; label gating) — align with 0019
   §3.1's YAML gate.
6. The notify JSON body's field set (§8), and whether `mentat run`
   completion firing is default-on or config-gated.
7. The park TTL default and its interaction with the wall-clock deadline
   (a parked child is alive but idle; the deadline must not reap a run
   that is waiting on its owner).
