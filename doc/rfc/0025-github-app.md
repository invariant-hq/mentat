# RFC 0025: The GitHub App — client-owned identity for routines

- Status: `discussion`. (Lifecycle: `ideation → discussion → published →
  committed | abandoned`.) Author: mentat campaign. Date: 2026-08-27.
- Audience: Mentat maintainers; the routine/mentatd (RFC 0024) and GitHub
  connector (RFC 0019/0020) authors
- Derives from: RFC 0024 (laws N1–N9; §2 routine custody; §3 the trigger
  path; §4 ingress; §7 the publisher; the receipt vocabulary), RFC 0019
  (laws C1–C8, all untouched), RFC 0020 (the pure renderer; §10's
  resident-connector invariants), and the code seams cited inline.
- Amends: RFC 0020 §10's "PAT-only in V1" clause and its pairing of App
  identity with the relay future, and RFC 0024 §11.2's adoption of that
  pairing (§6's ledger); `doc/manual/routines.md`'s default credential
  journey (the two-PAT section demotes to the fallback path).
- Maintainer mandate (2026-08-27, fixed): **client-owned GitHub App auth is
  mentatd's default GitHub UX**, replacing the two-PAT dance; PATs remain a
  supported fallback mode and the only mode for non-GitHub forges; the
  Invariant-owned multi-tenant App and the relay are the fleet's, out of
  scope here.

## Summary

Today a routine authenticates to GitHub with two fine-grained personal
access tokens the owner mints by hand in GitHub's settings UI, scopes by
hand, files under `secrets/`, and re-mints when the expiry calendar comes
due — twice per routine, attributed to a person unless they also maintain a
machine account, plus one webhook per repository whose secret and URL they
paste across. GitHub built a first-class instrument for exactly this job —
the GitHub App — and its manifest flow can create one in a single browser
click. This RFC makes that the default, in one sentence:

> **One verb creates the owner's own App; routines authenticate through
> it from then on.** `mentatd github setup` drives GitHub's app-manifest
> flow — the browser opens on GitHub's pre-filled create page, the owner
> clicks once, GitHub redirects to a one-shot loopback listener with a
> conversion code, mentat exchanges it and stores the App's credentials
> owner-level — and every routine with no PAT files resolves its GitHub
> identity to that App: short-lived installation tokens for the fetch and
> the reads, a separately-minted write-scoped token for the publisher
> child, reviews posted as `<app-name>[bot]`, and one App-level webhook
> covering every installed repository.

Nothing in the pipeline's shape moves. The read token already reaches git
as `basic x-access-token:<token>` per-invocation configuration
(`bin/boot/routine_fire.ml:269-274`) — the exact header an installation
token uses; the API client already speaks Bearer (`bin/github/github_api.mli`);
the publisher child already takes `GITHUB_TOKEN` from its environment
(`bin/boot/routine_fire.ml:722`); the run child already receives no GitHub
credential at all (`:171`). App mode changes *where the token comes from* —
minted, scoped, expiring within the hour — never where it goes, so N9's
custody map is preserved line for line while every credential in it gets
strictly shorter-lived.

The build is honest about its direction: the tree grows (≈ +1,000–1,400
impl; §6), because the PAT path is retained as the fallback the mandate
requires. What shrinks is the owner's surface: credentials to mint per
repository drop from two to zero, webhook configurations per repository
from one to zero, calendar expiries per routine from two to zero, and the
manual's machine-account apology paragraph deletes outright — the App *is*
the machine account, revocable in one place without touching anyone's
personal tokens.

## Motivation

The two-PAT journey is the worst prose in `doc/manual/routines.md`, and
not because the writing is bad. It needs a table to explain which of two
tokens does what; it warns that tokens minted from different accounts
stack comments instead of converging; it recommends operating a second
GitHub account to get honest attribution; and it leaves the owner holding
an expiry calendar GitHub deliberately imposes on fine-grained PATs.
Every one of those paragraphs is the surface telling us it is wrong —
the prose test RFC 0024 applies to its own verbs, failed by our default
credential story.

RFC 0020 §10 ruled "PAT-only in V1" and paired App identity with the
relay future. Both halves of that ruling have expired. The cost half was
priced when the tree had "no JWT, RS256, or HMAC code at all" — since
then the ingress landed HMAC-SHA256 over digestif/eqaf, and the TLS stack
carries RS256's entire raw material (§2.4: zero new packages). The
pairing half conflated two different Apps: the *Invariant-owned* App that
fronts many owners is inseparable from the relay and stays with the
fleet, but a *client-owned* App is just a better credential for the node
the owner already runs — no new transport, no tenancy, no vendor custody.
The mandate splits them accordingly.

## 1. Guide-level: the owner's journey

### Fresh setup

```
$ mentatd github setup
Opening GitHub to create your App (or open this yourself):
  https://github.com/settings/apps/new?state=…
Waiting for GitHub's redirect on 127.0.0.1:8917 …
```

The browser shows GitHub's own "Create GitHub App" page, pre-filled: a
generated name (editable in place — GitHub App names are global, so the
pre-fill carries a random suffix; if the owner picks a taken name,
GitHub's page says so and lets them edit), the three permissions
(Contents: read, Pull requests: write, Metadata: read), the
`pull_request` event, webhook settings the owner never touches. One
click on **Create GitHub App**. GitHub redirects to the loopback
listener, which answers "Done — you can close this tab", and the verb
finishes:

```
Created GitHub App "mentat-review-a3f9" (app id 12345).
  credentials: ~/.config/mentat/github-app (owner-only files)
  reviews will post as mentat-review-a3f9[bot]
Install it on the repositories your routines watch:
  https://github.com/apps/mentat-review-a3f9/installations/new
Webhook: not routed yet — deliveries start after
  `mentatd github repoint <public-url>`; the cron sweep needs no webhook.
```

The owner clicks the install link, picks the repository (or all), and
installs — GitHub's own page, one more click. Then:

```
$ mentatd routine add ./pr-review
Installed routine pr-review (digest 9f2c1a4e…).
  auth: GitHub App mentat-review-a3f9 — posts as mentat-review-a3f9[bot]
  verify the installation covers acme/widgets: mentatd github status
```

No token minted, no secret pasted, no webhook configured on the
repository. The crontab line from the manual works as-is; a resident node
with a tunnel runs `mentatd github repoint https://hooks.example.com`
once, and every installed repository's deliveries arrive from then on.

```
$ mentatd github status
app: mentat-review-a3f9 (id 12345) — reachable
webhook: https://hooks.example.com/ingress/github/1f0c… — current
pr-review  acme/widgets  app-auth  installation 987 — ok
```

### Adding a second repo later

If the App was installed on all repositories, `mentatd routine add
./other-review` is the entire journey. If it was installed per-repository,
one click on the same installations page first. Compare the PAT journey
this replaces: two tokens minted and scoped in the GitHub UI, two files
written 0600, one webhook created with a pasted secret and URL.

### The fallback, unchanged

An owner who cannot create an App (org policy), watches a non-GitHub
forge one day, or simply prefers tokens writes `secrets/read-token` and
`secrets/write-token` into the routine exactly as the manual documents
today, and that routine is a PAT routine: per-routine webhook identity,
per-routine secret, the existing journey end to end. Nothing is removed.

## 2. Reference-level

### 2.1 The credential home

App credentials are **owner-level** — one App serves every routine, the
way one auth store serves every session — so they live beside the
routines, not inside one:

```
~/.config/mentat/github-app/          0700
  app.json                            0600   id, slug, name, client id,
                                             html_url, api base, created-at
  private-key.pem                     0600   the RS256 signing key
  webhook-secret                      0600   the App-level HMAC key
  ingress.id                          0600   the App's minted ingress path token
  public-url                          0600   written by repoint; absent = unrouted
```

`User_dirs.github_app_dir` is `config_home / "github-app"`, and the store
is a boot-side module beside `routine_store` with the same custody
discipline: a group- or world-accessible directory or file is refused at
load the way sshd refuses a loose key, and a half-present home (an
`app.json` without its key, or the reverse) is refused whole — §3's A6
makes setup atomic so this state indicates tampering or a torn copy,
never a normal outcome. The private key is re-read from disk at each JWT
mint, exactly as routine secrets are re-read per fire: the file is the
registration, so replacing the key file is in force at the next event
with no reload protocol.

The manifest conversion also returns a client secret. It is
**discarded, deliberately**: it authenticates user-to-server OAuth flows
this design never performs, an unused credential on disk is pure
liability, and GitHub can mint a fresh one from the App settings page if
a future design ever needs it. `app.json` keeps the client *id* — it is
public identity, and GitHub's current guidance prefers it as the JWT
issuer.

`app.json` records the API base URL the App was created against
(`https://api.github.com`, or a GHES host — `setup` accepts the same
base-URL override the daemon does). A node or fire configured with a
different base refuses the App loudly rather than sending a JWT minted
for one host to another.

### 2.2 Which mode a routine is in

A routine's auth mode is decided by **file presence, per routine, PAT
files winning**:

- `secrets/read-token` or `secrets/write-token` present → a **PAT
  routine**, both roles: the existing journey, byte for byte. Mixing
  roles across identities is exactly the comment-stacking failure the
  manual warns about, so half-and-half is not a mode — either file makes
  the whole routine PAT.
- Neither present, and the credential home loads → an **App routine**.
- Neither present, no credential home → refused at fire time, naming both
  exits: "install the App (`mentatd github setup`) or write
  `secrets/read-token`".

The selector is deliberately *not* a `routine.json` member: `secrets/`
is already excluded from the policy digest, so switching a routine's
auth mode never moves its digest and never re-admits every open head —
identity is custody, not policy. The cost of implicitness is a possible
silent surprise (a stale token file pinning a routine to PAT mode), paid
down by printing: `routine add`, `routine list`, `routine status`, and
`mentatd github status` all name each routine's mode and posting
identity. The explicit-member alternative is recorded in §7.

One load rule becomes mode-aware: today a webhook routine without
`ingress.id`/`secrets/webhook` is refused with the hint to run `routine
add` (`bin/boot/routine_store.mli:69-77`). An App routine has no
per-routine webhook identity to demand — deliveries arrive on the App's
ingress id (§2.6) — so the refusal applies to PAT routines only, and
`routine add` skips the per-routine mint entirely for an App routine
(there is nothing to paste into GitHub settings). The v1 grant envelope,
the routine schema, and the digest definition are untouched.

### 2.3 `mentatd github setup` — the manifest flow

The verb lives on `mentatd`, in a new `github` group beside `routine`.
The honest weighing: `mentat` also owns `github review`/`github publish`,
but those are pipeline plumbing spawned as children; the App exists to
serve routines, routines are the unattended layer's configuration, and
RFC 0024's verb ruling (ssh/sshd: each product owns its own tooling) puts
the owner-facing App surface where the routines are. A user who never
runs unattended operation never sees it.

Mechanics, in order:

1. Mint a 128-bit `state` token and the App's `ingress.id` (same entropy
   class as a routine's). Bind the loopback listener — a fixed default
   port (`--port` overrides; the port must be known before the manifest
   is rendered, because the manifest carries the redirect URL). The
   listener is the one-shot state-checked loopback await the provider
   login already built (`lib/provider_runtime/oauth_flow.mli:62-86`):
   first matching request wins, stray requests (a favicon probe, a wrong
   `state`) are answered and do **not** consume the shot, and the wait
   times out at ten minutes with exit 1.
2. Serve the flow's entry page on that listener and open the browser on
   it (printing the URL regardless — a headless box's owner can run
   setup wherever a browser lives and copy the credential home over,
   since provisioning is files, RFC 0024 §10): the page auto-submits the
   manifest as a form POST to
   `https://github.com/settings/apps/new?state=<state>` (or
   `/organizations/<org>/settings/apps/new` under `--org`). The
   manifest:

   ```json
   { "name": "mentat-review-<4 hex>",
     "url": "<the product homepage constant>",
     "public": false,
     "redirect_url": "http://127.0.0.1:<port>/callback",
     "hook_attributes": { "url": "<derived>", "active": true },
     "default_events": ["pull_request"],
     "default_permissions": { "contents": "read",
                              "pull_requests": "write",
                              "metadata": "read" } }
   ```

   `public: false` — only this owner installs it; the public App is the
   fleet's. The hook URL is derived from `--public-url` when the owner
   already has a tunnel (`https://<host>/ingress/github/<ingress.id>`),
   and is otherwise an RFC 2606 `.invalid` placeholder: the webhook is
   born **active** with an unroutable target rather than born inactive,
   because `PATCH /app/hook/config` can re-point a URL and rotate a
   secret but carries no `active` flag — an inactive-at-birth hook would
   need a by-hand visit to GitHub's settings page to switch on, a hidden
   manual step this design refuses. Undelivered pings to the placeholder
   are red lines in the App's delivery log and nothing else; the sweep
   is the trigger until `repoint`, and the verb says so.
3. GitHub redirects the browser to the listener with a one-time `code`
   (and the `state`, verified). Exchange it —
   `POST /app-manifests/<code>/conversions`, unauthenticated by design,
   over the same first-party HTTPS client the connector already uses —
   and receive id, slug, name, client id and secret, webhook secret, and
   the PEM key.
4. Write the credential home **atomically**: a fresh temporary directory
   under the config home, all files 0600, renamed into place — the home
   exists complete or not at all (A6). Then print §1's summary.

Name collision needs no code: GitHub's own create page validates the
name field and the owner edits it in place; the conversion returns
whatever name was actually chosen, and the slug — the `[bot]` identity —
is stored from the response, never derived locally.

### 2.4 Tokens: the JWT, the mint, the scope, and the cache that is not

**The dependency question, answered concretely.** An RS256 GitHub App
JWT needs: base64url — `base64.3.5.2`, already linked by `bin/boot` for
the git auth header; PEM decode — `X509.Private_key.decode_pem`,
`x509.1.1.1`; RSASSA-PKCS1-v1.5-SHA256 —
`Mirage_crypto_pk.Rsa.PKCS1.sign ~hash:` `` `SHA256 ``,
`mirage-crypto-pk.2.4.0` (deterministic; no RNG on the signing path).
All of these are **already in `dune.lock`** — they ride in with
`tls.2.1.2`, which the provider transport's outbound HTTPS keeps in the
tree (RFC 0024 §11.5) — so the cost is new `libraries` lines on the
executable-side GitHub stanza, the digestif/eqaf ingress precedent
exactly, and **zero new packages**. The JWT module is small and boring:
header `{"alg":"RS256","typ":"JWT"}`, claims `iat = now − 60 s` (clock
skew), `exp = now + 9 min` (GitHub caps at 10), `iss` = the client id
(GitHub's preferred issuer; the numeric app id is stored too and
accepted), signed, three base64url segments joined. One pinned test
vector against a fixed key keeps the encoding honest.

**Resolution and mint, per fire.** routine → repository →
`GET /repos/<owner>/<repo>/installation` (JWT-authenticated) →
installation id → `POST /app/installations/<id>/access_tokens` with
explicit narrowing in the request body: `repositories` naming the one
repository the routine watches, and `permissions` naming only what this
mint's consumer needs. Two mints, because N9 splits the roles:

- the **read mint** — `contents: read`, `pull_requests: read` (metadata
  rides along) — feeds the git fetch and the three API reads;
- the **write mint** — `pull_requests: write` — is minted at publish
  time and handed to the poster child alone, exactly where
  `secrets/write-token` is read today (`bin/boot/routine_fire.ml:674`).

Installation tokens live at most one hour; a write token is live for the
seconds a publication takes. A leaked write token is scoped to one
repository's pull-request comments and is dead within the hour — the
strict reduction of blast radius the mandate names.

**The cache that is not.** The funded slice mints **per fire, with no
token cache**. `Repo.t`'s own law is rebuild-per-fire with credentials
re-read per fire (`bin/mentatd/node.mli` — "nothing here retains a
returned value, and no caller may either"), and a token cache would be
the first held credential state in the node — a staleness class bought
to save two HTTPS round-trips per fire on a pipeline whose deliveries
are rare and whose sweep beats every ten minutes. The cache is the named
optimization, shape pinned now so it cannot grow wrong later: in-memory
only, keyed on `(installation, scope)`, re-mint under a five-minute
refresh margin, **never written to disk** — nothing that authenticates
may live under the cache home (RFC 0024 §3), and a durable token cache
would violate N5 besides. It lands when mint-rate limits or latency
measurably bite, not before.

### 2.5 Where tokens flow — and where they never do

The custody map, unchanged in shape from today's PAT flow:

| Place | PAT mode (today) | App mode |
|---|---|---|
| git fetch | read-token, `http.<origin>/.extraheader` basic `x-access-token:…`, per-invocation env-scoped config | read mint, **same header, zero change** — installation tokens use exactly this scheme |
| API reads (head, listing, posted) | read-token as Bearer | read mint as Bearer, same client |
| publisher child | write-token in `GITHUB_TOKEN` env | write mint in `GITHUB_TOKEN` env |
| run child | **nothing** (env scrubbed, `routine_fire.ml:171`) | **nothing** — unchanged, A2 |
| renderer child | nothing (pure) | nothing |

The private key itself never enters any child environment or argv and
never leaves the fire/node process; only minted installation tokens
flow. This is the same custody the write-token already has — the fire
process reads it into memory for the moment it builds the poster child's
environment — with the file replaced by a mint.

**One real seam moves: the posted-comments identity.** The publisher
decides which existing comments are *ours* by author login, and today
that login comes from `GET /user` with the read credential
(`bin/github/github_reads.ml:89-99`). An installation token cannot call
`/user` (403 by design). In App mode the posting identity is knowable
without any network call: `<slug>[bot]`, from `app.json`.
`Github_reads.posted` therefore takes its identity from the caller —
the PAT arm resolves `/user` as today, the App arm passes the stored
bot login — and the convergence predicate (marker ∧ author, RFC 0020
L2) is otherwise untouched.

**Mode switch and convergence, stated plainly.** Comments posted under
a PAT identity are invisible to the App identity's *ours* filter and
vice versa. Settled heads are safe — their egress receipts exist, so
nothing re-publishes — but a PR reviewed under both identities across a
switch will carry the old identity's summary until a human deletes it,
and a still-standing finding whose thread was posted by the old
identity is re-posted once by the new one. One-time, per-PR, at
switch — the manual's migration note says exactly this, and the fix is
the owner deleting the old bot's comments or letting the PR close.

### 2.6 Ingress under the App

An App has **one** webhook: one URL, one secret, deliveries for every
installed repository. The per-routine ingress identity cannot carry
that, so App mode adds one binding rather than bending N routine
bindings:

- **One App-level ingress id.** `POST /ingress/github/<app-ingress-id>`,
  minted once at setup into `github-app/ingress.id`, resolving to the
  App's webhook secret with `enabled = true` while the credential home
  loads. The listener's contract is byte-identical — same route family,
  same `X-Hub-Signature-256` HMAC over the raw body, same constant-time
  compare, same content-free refusals — the resolver simply has one
  more source to scan beside the routine directories. The
  `Ingress.resolution` type (`lib/server/mentat_server.mli:159-175`) is
  unchanged.
- **Routing is by payload, after verification, App routines only.** A
  verified App delivery names its repository (`repository.full_name`);
  the node routes it to every *App-mode* routine watching that
  repository, running each through `admit_delivery` — N3 holds
  per routine: every matched routine's delivery receipt is durable
  before the 202, and any receipt failure is the same 500 the
  per-routine path answers. A pull-request delivery for a repository no
  App routine watches is a trace-log note and a 202, the same
  non-routine treatment pings and foreign event kinds get today
  (`bin/mentatd/node.mli`, the ingress contract) — the owner installed
  the App more widely than they routine, which is their business, not
  an error. PAT routines are deliberately **excluded** from App
  routing: they have their own ingress id and repo webhook, and routing
  both would receipt every delivery twice (the run-claim would collapse
  the duplicate to `dup`, but double receipts for one arrival is noise
  by design, not resilience).
- **The weighing, recorded.** The alternative — retaining per-routine
  ingress ids in App mode, all verifying against the App secret — is
  incoherent at the source: GitHub offers the App exactly one hook URL,
  so per-routine paths would require keeping per-repository webhooks,
  which is the tax this design exists to delete. Single-id-plus-routing
  deletes: the per-routine webhook mint in App mode, the per-routine
  secret file, the GitHub webhook settings walk per repository, and the
  per-repository URL/secret drift surface. It costs: routing moves from
  the URL path to the verified payload (a pure fold, unit-tested beside
  `event_route`), and one secret now guards all routines' deliveries —
  acceptable because the HMAC gate was never the authorization boundary
  (the gate, fences, and claim are), and rotation is one verb (§2.7).
- `mentatd routine rotate-secret NAME` keeps its meaning for PAT
  routines and refuses on an App routine, naming `mentatd github
  rotate-secret` instead — a per-routine verb must not silently act on
  owner-level state.

### 2.7 The doctor and the hook-config projection

Three more verbs complete the `github` group, all thin:

- **`mentatd github status`** — the doctor. Local half (no network):
  the credential home present, complete, and private; each routine's
  mode and posting identity. Network half: `GET /app` under a
  fresh-minted JWT (the App still exists and the key still signs);
  `GET /app/hook/config` (prints the live hook URL, flags the
  placeholder or a URL that differs from the one local files derive);
  `GET /app/installations` and, per App routine,
  `GET /repos/<owner>/<repo>/installation` (installation present, or
  the install link printed). Exit 0 all green, 1 otherwise — the
  pre-flight the owner runs when anything looks wrong, and the check
  `routine add` points at rather than performing itself (`add` stays
  network-free, like every non-fire routine verb).
- **`mentatd github repoint PUBLIC-URL`** — writes `public-url`, then
  upserts the whole hook config.
- **`mentatd github rotate-secret`** — mints a fresh webhook secret,
  writes the file, then upserts the whole hook config.

The last two share one discipline: **GitHub's hook config is a
projection of the credential home.** Both verbs write their local file
first (local truth durable first), then `PATCH /app/hook/config` with
the *complete* config derived from files — URL from
`public-url` + `ingress.id`, secret from `webhook-secret`,
`content_type: json`. A PATCH that fails leaves local truth ahead of
GitHub and the verb exits 1 saying "re-run"; re-running either verb
converges, because the upsert is total. Reconcile-by-observe, the C2
posture applied to configuration. (A secret edited by hand in GitHub's
UI is the one drift the doctor cannot see — the config read returns no
secret — and it surfaces as the 401 counter climbing while the sweep
keeps reviews flowing; rotate-secret is the repair.)

There is deliberately no `mentatd github remove`: the credential home is
files, removal is `rm -r` (documented, with the reminder that the App
itself is deleted from its GitHub settings page — no API deletes an
App), and a verb that shells out to `rm` would be ceremony.

### 2.8 Failure modes

Each row maps onto RFC 0024 §12's existing vocabulary — no new receipt
kinds, no new alert transitions; the credential rows generalize from
"token file" to "credential source", which the receipt already names.

| Failure | Carried by | Owner sees | Recovery | Lane |
|---|---|---|---|---|
| App deleted on GitHub (JWT answers 401) | receipt `refused(credential:app)` | one alert per window naming the app home | re-run `github setup`; or write PAT files (fallback) | process |
| private key rotated on GitHub's side (old key signs, GitHub refuses) | receipt `refused(credential:app)` | same alert | replace `private-key.pem` (files are provisioning) or re-run setup | process |
| installation revoked / repo removed from installation | receipt `refused(no_installation)` | one alert per window, install URL in the message | one click on the installations page; next delivery or sweep proceeds | process |
| token mint 401/403/5xx | receipt `refused(credential:app)` | one alert per window | transient: next sweep converges; durable: doctor names it | process |
| write mint fails at publish (read side healthy) | egress `skipped` naming the mint failure | alert as publication failure today | sweep's publisher re-entry re-mints and retries; spends nothing | process |
| App webhook secret drift (hand-edited on GitHub) | 401 counter climbs; reviews still flow via sweep | threshold alert; doctor cannot see the secret | `mentatd github rotate-secret` | node event |
| hook still on the placeholder URL | red deliveries in GitHub's App log; sweep-paced reviews | `github status` flags it | `mentatd github repoint` | node event |
| delivery for an uninstalled/unroutineed repo | trace log note | status counters | none needed — not an error | node event |
| half-written credential home | refused at load, whole | the load error | re-run setup (atomic write makes this tampering or a torn copy, not a normal state) | node event |
| both modes absent (no App, no PAT files) | fire refuses, naming both exits | the refusal | `github setup` or write `secrets/read-token` | node event |

## 3. Laws

- **A1 — One App, owner-level; a routine selects a mode, never carries
  App credentials.** The credential home lives beside the routines, is
  never referenced from a routine directory, and can never lie under a
  run root (the config home is sandbox-denied to every confined run
  already; the existing layout refusal covers relocations). A routine
  proposal carrying App material is refused as one carrying `secrets/`
  is. *Prevents:* key sprawl per routine; a PR shipping the credentials
  that would review it.
- **A2 — The key signs; only tokens flow.** The private key never
  enters any child environment, any argv, or any file outside the
  credential home; the read mint reaches git and the API reads, the
  write mint reaches the publisher child alone, and the run child
  receives no GitHub credential of any kind — N9's map, unchanged.
  *Prevents:* the Actions secret-leak class escalated from a scoped
  token to the App's root key.
- **A3 — Every mint is narrowed, and no token touches disk.** Every
  installation-token request names its repository and its permissions
  explicitly — the read mint cannot write, the write mint reaches one
  repo's pull requests — and tokens live only in process memory (the
  named future cache included). *Prevents:* a confused-deputy publish
  against the wrong repository; a durable token outliving its hour.
- **A4 — Mode is per-routine, decided by files, PAT files winning, and
  always printed.** No ambient state flips a routine's identity
  silently: `add`, `list`, `status`, and the doctor all name the mode
  and the posting identity. *Prevents:* the App hijacking a
  deliberately-PAT routine (the forge-neutral fallback must stay
  reachable); a stale token file masquerading as App mode.
- **A5 — One hook, verified before routed.** The App's deliveries carry
  one secret over one URL; the ingress verifies the HMAC over the raw
  body exactly as the per-routine family does, and only a verified
  payload's repository member may select routines — App-mode routines
  only, each receipted before the 202 (N3 per routine). *Prevents:*
  unverified content choosing a routine; double receipts for one
  arrival.
- **A6 — Conversion or nothing.** Setup writes the credential home
  atomically — temporary directory, complete files, rename — and load
  refuses a partial home whole. *Prevents:* an app id without its key
  haunting every later mint with a half-diagnosable 401.
- **A7 — The callback is one-shot and state-bound.** The loopback
  listener accepts exactly one conversion, matched to the state token
  minted for this invocation; anything else — wrong state, stray
  request — is answered and does not consume the shot, and the wait
  expires loudly. *Prevents:* a CSRF'd foreign conversion code becoming
  the owner's stored App; a browser probe eating the redirect.
- **A8 — GitHub's hook config is a projection of local files.** `setup`,
  `repoint`, and `rotate-secret` all derive the complete config from the
  credential home and upsert it whole; local files are written first;
  re-running converges. *Prevents:* URL/secret drift with no
  reconciliation story; a rotation that updates one side.

## 4. Drawbacks

- **The tree grows and deletes little code**, because the mandate keeps
  the PAT path whole as fallback and forge-neutral floor. The ledger
  (§6) counts the growth honestly; the deletion is owner-side surface,
  not LOC.
- **One more GitHub API surface owned forever**: the manifest
  conversion, the installation/token endpoints, and the hook-config
  PATCH join the drift-watch list beside the event vocabulary.
- **Setup wants a browser on the machine** (or a copied credential home,
  or `--port` over an SSH forward). The PAT path remains the no-browser
  story.
- **The mode switch republishes once per straddling PR** (§2.5) — a
  real, bounded migration wart, documented rather than engineered away.
- **A5 narrows webhook blast radius less than the per-routine design
  did**: one leaked App secret forges deliveries for all App routines,
  where a per-routine secret forged one. The gate/fence/claim ladder —
  which never trusted the HMAC as authorization — and the one-verb
  rotation are the compensations, and the trade buys the deletion of
  N webhook configurations.

## 5. Rationale and alternatives

**PATs forever (do nothing).** The strongest incumbent: zero build, the
crontab story already works. Rejected as the *default* because the
credential journey is the worst surface the routine product has — two
hand-minted tokens per routine, expiry calendars, person-attribution
unless a second account is operated, per-repo webhook plumbing — and
every one of those is exactly what GitHub Apps exist to remove. Retained
in full as the fallback and the non-GitHub-forge mode.

**Per-routine Apps.** Mirrors the per-routine secret custody, so no
owner-level state. Rejected: N manifest dances, N private keys, N
webhook configs — it recreates the per-repository tax at higher ceremony
and multiplies exactly the credential that matters most. mentatd is
single-owner by law (RFC 0024); one owner is one trust domain is one
App. The fleet's many-owner problem is the Invariant App's, out of
scope by mandate.

**Device flow (or any OAuth user flow) instead of the manifest.**
Rejected as the wrong instrument, not a variant: OAuth flows mint
*user* tokens — a fancier PAT, attributed to the person, 8-hour
expiring with a resident refresh dance, no `[bot]` identity, no
installation scoping, no App webhook. The manifest flow is the only
path that *creates the App itself*, which is the thing a token can
never become. (It is also why the client secret can be discarded:
adopting user-to-server OAuth later is an additive design, §8.)

**An explicit `auth` member in `routine.json`.** Honest and greppable,
but it puts identity into the policy digest — switching modes would
re-admit every open head for a change that alters no policy — or forces
a special "member excluded from the digest" carve-out, a second
exclusion rule beside `secrets/`. File presence keeps identity in the
custody plane where the digest already ignores it. The printing
obligation (A4) is the mitigation for implicitness.

**Webhook inactive at birth, activated when the tunnel exists.**
Cleaner-looking than a `.invalid` placeholder, and rejected on an API
fact: `PATCH /app/hook/config` cannot flip `active`, so activation
would be a by-hand visit to GitHub's settings — a hidden manual step on
the default path. The placeholder keeps every post-setup motion a verb.

**Reusing the web mount for the callback.** Already ruled out by
RFC 0020 §9 for its CSP (`form-action 'self'`) and `SameSite=Strict`
cookie — and mentatd may not even be running at setup time. The
one-shot loopback listener the provider login built is the right shape
and already exists.

**Minting one broad token per fire instead of two narrow ones.** Fewer
round-trips, rejected: it would put a write-capable token in the fire
process for the whole run window and hand the publisher more than it
needs, walking back the C5/N9 split for two HTTPS calls.

## 6. The ledger

What this deletes or prevents:

| Deletion / prevention | Surface |
|---|---|
| The two-PAT minting journey as the default path | the manual's "two credentials" table, the scoping walk, and the expiry story demote to a fallback section (~60 lines of default-path prose) |
| The machine-account recommendation | deleted outright — the App is the machine account; `<name>[bot]` attribution and one-place revocation are structural |
| PAT-expiry calendar risk | App-mode routines hold no expiring credential; the §12 dead-token row becomes unreachable for them by construction |
| Per-repository webhook configuration | N repo webhooks (URL + pasted secret each, tracking every tunnel move) → one App hook, re-pointed by one verb |
| Per-routine webhook secret custody in App mode | N `secrets/webhook` files → one owner-level file |
| Read/write identity-mismatch comment stacking | impossible in App mode — one App is both identities |
| The unused client secret on disk | prevented — discarded at conversion |
| A durable token cache | prevented — A3; the future cache is pinned in-memory |
| RFC 0020 §10's stale cost claim | "the tree has no JWT, RS256, or HMAC code at all" retired; the App-relay pairing corrected to fleet-App-only |

What it adds, priced against the repo's measured density: the credential
store + custody (~150–200); JWT + conversion + mints (~200–300, zero new
packages); setup + the callback (~200–300, reusing the loopback await);
doctor/repoint/rotate (~200–300); mode resolution in `routine_store`,
the `posted` identity seam, and pipeline plumbing (~150–250). **Impl
≈ 1,000–1,400 LOC**, tests per house norm ~400–700 (a pinned RS256
vector, conversion decode goldens, mode-resolution units, custody and
half-home refusal goldens, hook-config projection goldens, verb crams).
**Path ≈ 1,400–2,100 LOC**, all in the executables — no library, no
engine, no wire, no journal change, no routine-schema change.

The honest net: the tree grows by the full build (the PAT path sheds
nothing — it is the mandated fallback), and what shrinks is the owner's
operational surface: per-repository credentials 2 → 0, per-repository
webhook configs 1 → 0, calendar expiries per routine 2 → 0, secrets on
disk per routine 3 → 0 (owner-level: 2 — one key, one webhook secret).
The deleted thing is the worst prose in the manual and the workflow it
describes.

## 7. Non-goals

- **The Invariant-owned multi-tenant App and the relay** — the fleet's,
  with RFC 0024 §10's invariants; nothing here presumes or precludes
  them.
- **GitLab and other forges** — the webhook substrate is forge-neutral
  and PATs remain their mode; a forge arm is a named future, not
  designed here.
- **Org-level installation UX beyond what the manifest flow gives** —
  `--org` targets the org's create page; SSO, IP allow-lists, and
  enterprise policy surfaces are the owner's to navigate on GitHub.
- **User-to-server OAuth** (the discarded client secret's consumer),
  **check runs** (RFC 0020 §9's trigger is only one-third satisfied:
  an App identity now exists, but neither the required-gate want nor
  the unconditional ingress), and **`REQUEST_CHANGES`/`APPROVE`** —
  all keep their existing deferrals.

## 8. Unresolved questions

**Blocking before merge:**

1. The mode selector — file presence with PAT files winning (§2.2)
   versus an explicit routine member — is this RFC's most owner-visible
   ruling and touches `routine_store.load`'s refusal behavior; it needs
   the maintainer's yes.
2. The single-App-ingress-with-payload-routing shape (§2.6), since it
   fixes how N3's per-routine receipt discipline meets a many-routine
   delivery and what `rotate-secret` means in each mode.

**During implementation:**

3. Verify against live GitHub: the manifest's accepted `hook_attributes`
   grammar with a placeholder URL (the fallback ladder if a URL is
   refused: omit `hook_attributes` and document the one-time manual
   activation — the known cost §5 records); and whether conversion
   responses ever omit `webhook_secret` when the hook is placeholder'd.
4. The JWT `iss` choice (client id preferred, app id fallback) and the
   exact skew/lifetime constants — both stored, so this is a constant,
   not a schema.
5. The doctor's exact output bytes and exit taxonomy; the setup entry
   page's bytes; the fixed default callback port.
6. Whether `github status` should also verify the hook URL end-to-end by
   observing a redelivered ping, or leave delivery health to GitHub's
   own log.

**Out of scope** (tiered out, not open): everything in §7; the relay
handshake; the in-memory token cache (named future, shape pinned in
§2.4).

## 9. Future possibilities

The ingress seam admits a delivery from a direct webhook or a future
relay connection — the listener hands verified bytes to the same
callback either way — so the fleet's relay plugs in without rework. A
forge arm (GitLab first) would promote the connector per RFC 0019 and
ride the PAT mode this RFC keeps whole. The token cache lands behind
measured mint pressure. A check run returns when RFC 0020 §9's remaining
triggers fire, now that its App-identity precondition is met. *Nothing
in this section is a reason to accept this RFC.*
