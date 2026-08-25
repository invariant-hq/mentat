# RFC 0020: `mentat github review` — findings as review threads

- Status: `discussion`. (Lifecycle: `ideation → discussion → published →
  committed | abandoned`. `committed` means the document describes how the
  system works, not what we intend.)
- Audience: Mentat maintainers; the executable (RFC 0014) and session
  (RFC 0005) authors
- Derives from: RFC 0019 (laws C1–C8; the findings document as the sole
  run↔projection interface; the Stage-1 workflow this plugs into),
  RFC 0014 (executable-private policy)
- Amends: RFC 0019 §2, §9 — see the ledger in §8. Not purely additive.
- Provenance: three blind designs, a code + API audit, and four review lenses
  (correctness, cost, simplicity, design-quality). The design-quality pass
  replaced the shape entirely; §7 records what each pass changed.

## Summary

RFC 0019's reviewer produces typed findings and posts them as one summary
comment. This RFC makes them land as **review threads on the diff**, and it
does so by adding **one total function** to the binary:

> a findings document and the diff it was produced against, in;
> the GitHub request bodies that publish it, out.

No HTTP client, no transport, no retry policy, no daemon. The workflow already
has `gh` and already sends bytes to GitHub; RFC 0019 named the three things
that deserved typed OCaml — the anchoring partition, fingerprint convergence,
and re-anchoring across pushes — and **all three are pure**. So the funded
artifact is a renderer whose output the existing workflow pipes to `gh api`,
and whose entire test estate is byte-goldens on stdout.

Everything else the campaign designed — the check run, thread resolution,
suggestion blocks, the install wizard, the App flow, the resident daemon — is
deferred behind a checkable trigger (§9), and the deferral table is this RFC's
second most important content.

## Motivation

A finding that says `lib/config.ml:88` is only useful next to line 88. RFC
0019 shipped the summary comment because inline anchoring is the field's most
bug-prone surface and it wanted the cheap thing first. That was right, and the
debt is now due: a maintainer reading a table of permalinks is doing the
publisher's job by hand.

## 1. Guide-level: what this produces

A thread on the diff:

```markdown
🔴 **P0 — Null deref when the config file is empty**

`Config.get` returns `None` for an empty file, but line 88 unwraps with
`Option.get`, so an empty `.mentat/config` crashes at startup before a
session exists.

<sub>mentat · <!-- mentat-finding:9f2c1a4e7b3d8065 origin=actions --></sub>
```

and one summary comment, upserted in place, carrying the verdict plus
**only what could not become a thread**:

```markdown
### 🔴 Mentat review — 1 blocking finding

Reviewed `a1b2c3d` against `main` · 3 findings · 2 threads posted

**Not anchored to the diff:**

| | Finding | Location |
|---|---|---|
| 🟡 P2 | `Config.get`'s only other caller unwraps too | [`bin/main.ml:204`](…/blob/a1b2c3d/bin/main.ml#L204) |

<sub>mentat 0.4.0 · claude-fable-5 · [run](…) · <!-- mentat-review origin=actions -->
</sub>
```

The two surfaces have **disjoint contents**: a finding is either a thread or a
summary row, never both. That is why there is no "renders twice" caveat and no
third row kind.

The workflow, replacing RFC 0019's posting script:

```yaml
- run: |
    { gh api --paginate "/repos/$R/pulls/$N/comments" \
        --jq '.[] | {id: .id, body: .body, user: {login: .user.login}}'
      gh api --paginate "/repos/$R/issues/$N/comments" \
        --jq '.[] | {id: .id, body: .body, user: {login: .user.login}}'
    } | jq -s 'map(select(.user.login == "github-actions[bot]"
                 and (.body | test("<!-- mentat-(review|finding:)"))))' \
      > posted.json
- run: |
    jq -r 'select(.type=="turn.finished").output' run.jsonl \
    | mentat github review --pr "$R#$N" --at "$SHA" --origin actions \
        --diff pr.patch --posted posted.json > out.json
- run: |
    # one review-comment POST per thread; the summary request carries its
    # own method (POST the first run, PATCH thereafter)
    count="$(jq '.review | length' out.json)"; i=0
    while [ "$i" -lt "$count" ]; do
      jq ".review[$i].body" out.json > body.json
      gh api --method "$(jq -r ".review[$i].method" out.json)" \
        "$(jq -r ".review[$i].path" out.json)" --input body.json
      i=$((i + 1))
    done
    jq '.summary.body' out.json > body.json
    gh api --method "$(jq -r '.summary.method' out.json)" \
      "$(jq -r '.summary.path' out.json)" --input body.json
```

`pr.patch` is the merge-base diff **the review job already computed** (RFC
0019 §3.2 writes it into the worktree for the model to read). Uploading it
next to `run.jsonl` costs one line and means the publisher anchors against the
exact bytes the model reviewed — SHA pinning becomes structural rather than an
assertion, and no diff is re-fetched.

## 2. Reference-level: the design

### 2.1 Types

```
Finding.t        severity · path · anchor · title · Body.t
Body.t           model text, neutralized at construction (§2.4)
Diff.t           parsed unified diff: commentable lines + their text, at a head SHA
Anchored.t       Finding.t × Diff.t position × Fingerprint.t
Unanchored.t     Finding.t × permalink
Publication.t    threads · summary · the requests that publish them
```

`Anchored.t` and `Unanchored.t` are **two types, not a runtime partition**.
Consequences that stop being prose: `Fingerprint.t` is total (it exists only
where an anchor does); the review body can only be built from `Anchored.t`, so
"cannot 422 on a line error" is a signature rather than a promise; and
`commit_id` is projected off the anchor's `Diff.t`, so no call site can omit
it.

`Publication` is RFC 0019's own word (C2, C6). The pipeline reads:

```ocaml
let diff = Diff.of_unified ~head patch in
let pub  = Publication.of_findings ~diff ~policy ~posted findings in
Publication.requests pub          (* a labeled request list — the whole output *)
```

A request is `{ label : Finding.Id.t option; method_; path; body }`. It is
data: the same value is what the goldens assert, what stdout carries, and what
`gh` sends. There is no plan, no walker, and no interpreter — the caller is
`jq`.

### 2.2 Anchoring

Parse the supplied diff: walk each `@@ … +newStart @@` hunk, advancing the
RIGHT-side counter on context and added lines, collecting commentable lines
and their text. A finding is **anchored** when its `anchor` — the exact text
of the source line it is about (§8, a new schema field) — equals a
commentable line of its claimed file after trimming: uniquely, or at the
occurrence nearest its claimed `line`. The claimed line is a tiebreak, never
a gate — a quote that matches exactly one line anchors there even when the
claimed line is wrong, and a tie at equal distance refuses to anchor. A
quote that matches nowhere is **unanchored** and becomes a summary row.

Anchoring by quoted text rather than by line number is what makes the whole
convergence story fall out:

- Drift-immunity is structural. A finding whose surroundings shifted still
  matches its own text — and the dominant producer error, deriving absolute
  line numbers from `@@` offsets, cannot demote a finding whose quote is
  right.
- A hallucinated or out-of-diff finding **cannot** anchor, so RFC 0019 §3.3's
  "report only findings introduced by this change" becomes checkable instead
  of hoped-for. A wrong `line` is unfalsifiable; a wrong quote is not.
- No occurrence ordinal is needed: a duplicated quote (`in`, a closing
  paren) is disambiguated by the claimed line, and an honest tie stays
  unanchored rather than guessed.

Rename detection is the honest caveat, and it degrades to unanchored. If git's
and GitHub's hunk boundaries ever disagree (both default to three context
lines), the failure is a loud 422 on a request we can name — never a silent
comment on the wrong code.

### 2.3 Convergence: post what is new, never edit, never resolve

`posted.json` is the PR's existing review comments. A thread is **ours** only
if it carries our marker *and* its first comment's author is the configured
bot login — marker presence alone is forgeable on a public repo, and under a
never-repost rule a forged marker would suppress a real finding permanently.
The same author predicate governs the summary comment we upsert.

Let `F` be this run's anchored fingerprints and `E` ours already posted:
`F \ E` is posted as one review-comment POST per thread — a request GitHub
rejects fails alone, and convergence heals around it on the next run, where
a single batched review POST would fail *in toto* on one marginal anchor;
`F ∩ E` is left untouched; `E \ F` is **left alone**. The funded slice never
resolves a thread, because the producer is a model: a finding can vanish
from one run by flakiness, and resolve-on-absence composed with never-repost
would close a real P0 forever.

`Fingerprint.t` = the digest of `[path; anchor; title]` under the domain
`mentat.github.finding.v1`, 64 bits rendered as 16 lowercase hex — ample at
review scale, where the set is tens of items per PR. The derivation is the
digest library's length-framed key (each member is length-prefixed before
hashing), so no member content can collide with a different `(path, anchor,
title)` split — and it is a wire format: fingerprints persist in GitHub
comments, so the derivation may never change silently (the unit suite pins
one literal hex value for exactly this reason).

**The known limit, stated plainly.** The fingerprint keys on code text, so the
*expected* user action — editing the flagged line to fix it — re-keys the
finding. The old thread stays open and a new one is not posted (the finding is
gone). Thread count is therefore monotone over a PR's life. That is the honest
cost of never resolving, and it is what the deferred resolution trigger (§9)
exists to revisit with data.

### 2.4 Neutralization by construction

`Body.of_model_text` is the only constructor of `Body.t`, and it neutralizes
HTML comment delimiters. Only `Marker.t` values emit `<!-- … -->`. A rendered
body therefore cannot contain a marker — by construction, not by remembering
to call a function at each site. This is a security invariant (a forged marker
suppresses findings), so it is held by a type.

Markers carry an origin discriminator from rung 0: `Marker.t` values render
as `<!-- mentat-review origin=<token> -->` and
`<!-- mentat-finding:<hex> origin=<token> -->`, the token supplied by
`--origin` — `ci` by default, `actions` in the shipped workflow,
`charter:<name>` at rung 1. The posted scanner keys on the marker prefix and
accepts both the origin-bearing grammar and the bare legacy one, so
convergence sees a thread regardless of which origin posted it: the
discriminator names the publisher, it never partitions dedup.

### 2.5 Verdict, and the one policy

`Policy.t` derives everything: `block_on` (default P0, P1) decides the badge
and **also decides what earns a thread** — blocking findings become threads,
the rest become summary rows. One policy, not a separate churn cap: the
product is better (threads carry weight), the knob count drops, and a bad run
cannot post forty comments because a run cannot have forty blocking findings
without the review itself being the problem.

There is no gate: no check run, no `REQUEST_CHANGES`, no `APPROVE`. The
workflow's own status row remains the machine-visible signal, and a required
check would be unsafe under RFC 0019's skipping ingress anyway (§9).

### 2.6 The command

```
mentat github review --pr OWNER/REPO#N --at SHA --diff FILE --posted FILE
  [--base-label REF] [--origin TOKEN]  < findings.json
```

Findings on stdin; a JSON envelope on stdout — the standard
`schema_version`/`type` envelope, type `github.review`, carrying `review`,
`summary`, and the `threads_safe` flag (see §4). `--base-label` only names,
in the summary, what the head was reviewed against; `--origin` stamps the
markers' origin discriminator (§2.4). Exit `0` on success, `2` on usage, `1`
if the findings, diff, or posted listing do not parse. It performs **no IO
beyond reading its inputs and writing stdout**, so it has no retry policy,
no partial-failure semantics, no `--dry-run` (it is always dry), and no
network at all.

Module map — two pure modules and a responder, all executable-private:

```
bin/cli_github.ml       the responder
bin/review_finding.ml   Finding.t, Body.t, Fingerprint.t, and the C6 decode
bin/publication.ml      Diff.t, Anchored.t, Unanchored.t, Publication.t
```

Tests are byte-goldens on stdout plus windtrap properties: the parser's
commentable set against synthesized diffs; anchor uniqueness and
drift-immunity; `F \ E` set algebra; and neutralization (a finding body
containing a marker, an `@mention`, a fence). No fake process, no fixtures for
a transport that does not exist.

## 3. Laws

- **L1 — The publisher performs no IO.** Its output is a value. *Prevents* the
  transport, retry, atomicity, and partial-failure machinery that a client
  would drag in, none of which the funded slice needs.
- **L2 — A thread is ours only if marker ∧ author.** *Prevents* a forged
  marker suppressing a real finding.
- **L3 — A rendered body cannot contain a marker.** Held by `Body.t`'s
  constructor. *Prevents* the same attack from the other direction.
- **L4 — Anchors are quoted text, matched in the reviewed diff.** *Prevents*
  silent mis-anchoring, and makes out-of-diff findings detectable.
- **L5 — Never resolve.** There is no function that resolves a thread and no
  GraphQL surface. *Prevents* a flaky absence permanently burying a finding.

## 4. Drawbacks

The posting loop moves to the workflow, where a reader can get it wrong; the
head-SHA guard surfaces as the `threads_safe` flag — when it is `false` no
thread requests are emitted, so the flag names why the list is empty rather
than gating requests the workflow could mistakenly send. A future
non-Actions caller would need transport in-process — but that caller is the
resident daemon, which is unfunded, and it would want a real HTTP client
rather than this command anyway. Retry becomes Actions' job-level retry; for
two writes that is a rounding error.

## 5. Rationale and alternatives

**An OCaml client (`gh.ml` + retry + temp bodies + a fake-`gh` test estate).**
Rejected: it funds a transport to perform two writes and three reads, adds a
Go CLI to the runtime prerequisites of a product that otherwise ships
dependency-free binaries, and types nothing RFC 0019 asked to be typed. The
question is not *which* transport but *whether the funded slice needs one*.

**A desired-state reconciler.** Rejected: two surfaces, two behaviors, and no
delete path by law (L5). A reconciler earns its keep at three-plus surfaces
with a delete path; here it is machinery over a variation of size two. Its
good idea — that the output should be a labeled request list rather than
intents a walker interprets — is adopted (§2.1).

**Line-number anchoring with an occurrence ordinal.** Rejected in favor of
quoted anchors (§2.2), which buy drift-immunity at the anchor layer instead of
reconstructing it at the fingerprint layer, and make hallucinated findings
detectable.

**Fetching the diff from `GET /compare`.** Rejected: the review job already
computed the exact diff; re-fetching it introduces pagination, a file cap, a
degrade rule, and a second source of truth for the same bytes.

**A check run as the gate.** Deferred (§9), not rejected on merit: it is the
right shape for a required status, but it needs `checks: write`, is
**App-only** (a PAT gets 403, so a local run cannot write one), and is unsafe
as a required check while the ingress skips runs.

## 6. Cost, success, and kill criterion

**Build:** ~600–900 lines including tests — two pure modules, a responder, and
goldens. (The client-shaped design this replaces priced at 1,400–2,200, and
the full campaign design at 10,000–17,000.)

**Ongoing:** permanent ownership of anchoring and fingerprint convergence,
which is the field's most bug-prone area. The dependency on GitHub's rendering
is now indirect — we parse our own git diff — which is the main reason this
shape is cheaper to maintain, not just to build.

**Success (30 days of dogfood):** a majority of posted threads are ones a
maintainer replies to, fixes, or explicitly dismisses; and no run posts a
thread anchored to code the finding was not about.

**Kill criterion:** if threads are routinely ignored while the summary is
read, delete the thread surface and keep the summary — the failure would be
that inline placement did not add signal, and the pure-renderer shape makes
that reversal cheap.

## 7. What the review lenses changed

Recorded because the deltas are the evidence. **Correctness** found eleven
blockers: silent mis-anchoring against a moving head (now structural, §1),
forgeable thread ownership (L2), a consent widening that would have let a PR
comment install standing user-config allow rules (§10), cross-repo approval
and stale-approval-after-restart, a principal codec that would have failed to
decode every existing journal, a mis-cited precedent, and the fact that check
runs are App-only. **Cost** priced the campaign design at ~8× the ask and
produced the minimum slice. **Design quality** replaced the shape: it found
that the RFC funded a transport without ever asking whether the slice needed
one, that the interface both RFCs call central had no type, that `Plan`
collided with the session vocabulary, and that four invariants held by prose
could be held by types. A **fold verification** pass then caught that the
previous revision claimed to be purely additive while silently closing six
RFC 0019 statements — which produced §8.

## 8. What this amends in RFC 0019

This RFC is **not** purely additive. The ledger:

1. **§2, the findings schema — adds a required `anchor` field** (the exact
   source text a finding is about) and drops nothing. The model already reads
   the diff, so quoting the flagged lines costs it nothing. The window is now:
   the schema is committed in-repo and no release has shipped it.
2. **§9, Stage 2 — retargeted.** 0019 listed the check run, auto-resolution,
   `suggestion` blocks, multi-line anchors, and App identity as Stage-2
   content. All are deferred here with triggers (§9). Stage 2's remaining
   promise — that findings become review threads — is what this RFC delivers.
3. **§9's "the findings schema ships from the binary"** — deferred with the
   install wizard; the committed schema stays for now. This answers 0019 open
   question 2 in the negative *for the funded slice only*.
4. **§9's fenced PR-context provisioning** — dropped, not deferred. PR title
   and body remain excluded; nothing needs them.
5. **§9's Stage 3 sketch** ("daemon + webhooks replace Actions", the principal
   landing "on the authenticated envelope route") — superseded by §10:
   ingestion would be polling, and the route must be off-wire.
6. **Open question 3 (required-status timing)** — answered: not while the
   ingress skips runs, and not at all until a check run exists.

## 9. Deferred, with triggers

| Deferred | Trigger |
|---|---|
| Check run + annotations | an App identity exists (PATs cannot write checks) **and** a required gate is wanted **and** the ingress is unconditional |
| Thread resolution | 30 days of dogfood; fires if >30% of findings recur across pushes on the same PR. Requires recording per-finding recurrence, which the funded slice does **not** do — that instrumentation is part of this trigger, not free |
| `suggestion` blocks, multi-line anchors | a maintainer request |
| `REQUEST_CHANGES` / `APPROVE` | a maintainer request; never a default |
| `.mentat/github/config.json` | the second distinct policy request (flags with defaults until then) |
| `install` / `doctor` / `--upgrade` / schema-from-binary | the first release is cut **and** one external adoption request |
| GitHub App wizard | evidence an adopter stalled on manual creation. It also cannot reuse the `serve --web` edge: that edge's CSP sets `form-action 'self'` and `script-src 'self'`, blocking both the cross-origin POST and the self-submitting script, and its `SameSite=Strict` cookie is withheld on GitHub's redirect. Until then, document the manual five-click path and accept `--app-id` / `--app-key-file`. Never a vendor-operated App |
| `@mentat` ask | 20 successful dogfood reviews. When built, gate on the collaborators API (`admin\|write\|maintain`) — `author_association: COLLABORATOR` includes read and triage access |
| `doc/manual/github.md` | the first external adoption request. Until then the dogfood path is documented in the existing headless page |
| Everything in §10 | RFC 0018's `Local_child`, a written PAT-only design, and a second user asking for `@mentat fix` |

Each trigger names an observable event. Re-evaluated at each release.

## 10. The resident connector — invariants only

Unfunded and unscheduled; pinned so a future implementation cannot violate it.

- **Polling, not webhooks**, for a local daemon: it has no public address, and
  a tunnel or relay is the vendor dependency C5 forbids. Conditional requests
  make idle polling free — but `ETag` matching needs a **fixed URL**, so a
  cursor cannot ride in the query string. (`X-Poll-Interval` is an Events-API
  header and does not apply.)
- **No durable intent machinery.** Inputs persist; everything else reconciles
  by observing GitHub markers.
- **Never the user's live tree** — an ephemeral per-PR worktree under a fresh
  registry root. (`get_or_boot ~root` gives capability isolation; the run
  fence is per-session, not per-root.)
- **The GitHub credential is a connector-owned 0600 file, never `auth.json`**
  — different trust domain from the model key (C5).
- **PAT-only in V1.** App identity needs RS256 JWT signing — PEM decode,
  PKCS#1 v1.5, claim/skew handling — and the tree has no JWT, RS256, or HMAC
  code at all. Webhooks add HMAC-SHA256. Naming these keeps the cost visible.
- **Write consent** discharges RFC 0019's C7 with a `Principal.Github of
  { installation; actor; association; verified_at }` arm — *not* a `forge`
  string field, which would be a forever-field in a durable journal for a
  variation nobody has. Four constraints the code forces: the codec cannot be
  an enum (an arm with a payload would rewrite every existing journal's
  encoding, so it must be a mixed string/object decoder); consent is
  `Allow Once | Deny` **only** (`Allow (Family {lifetime = User})` would
  install standing rules into the maintainer's user config, escaping the PR);
  the route must not live on `Driver.Session` (that surfaces on the client the
  loopback web edge holds) but on a connector-only cone with a dependency-law
  test; and approval must bind `(repo, pr, head_sha)`, since the decision id
  is published in the marker and carries no entropy.
- **A resident trigger is an availability regression** — it replaces an
  always-on, zero-ops, free trigger with a laptop process that sleeps with the
  lid and has no supervision story in-tree. Acceptance requires an autostart
  unit and a liveness signal.
- The Stage-3 fix flow additionally needs `contents: write`, and a fix
  touching `.github/workflows/**` needs the `workflows` permission or must
  degrade to a patch in a comment.

## 11. Unresolved questions

**Before merging this RFC:**

1. Adopting the `anchor` schema field (§8.1) amends RFC 0019 and must be
   ratified with it. If declined, anchoring falls back to line numbers plus an
   occurrence ordinal, and §2.2's hallucination check is lost — say so
   explicitly rather than letting it lapse.

**During implementation:**

2. Whether `threads_safe: false` (head moved under the run) should suppress
   only the threads or the whole publication. Recommendation: threads only —
   a stale summary is harmless and self-corrects on the next run.
3. Rename handling in the diff parser: degrade to unanchored, or follow
   `previous_filename`? Recommendation: degrade, with a golden.

**Explicitly out of scope:** everything in §9 and §10.

## 12. Future possibilities

Inline `suggestion` blocks; a check-run gate; delta reviews that examine only
what changed since the last reviewed SHA; a second forge. *Nothing in this
section is a reason to accept this RFC or a later one — if one of these
matters, it belongs in Motivation, there or here.*
