Rotating a webhook routine's HMAC secret re-mints the key in place. The
ingress URL never moves — rotation changes what signs deliveries, never
where they land — and the old secret stops verifying the moment the verb
returns: the owner sets the new one on the GitHub hook next (single-owner
law), and the sweep covers whatever the gap misses. The pin here is
store-level: the secret file's bytes change while the ingress id and the
loaded roster do not; the resolver re-reads bindings per request, so a
running node picks the fresh secret up at the next delivery by
construction.

  $ mkdir proposal
  $ cat > proposal/routine.json <<'EOF'
  > { "routine": 1, "name": "pr-review",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [
  >     { "kind": "github_webhook", "events": ["pull_request.opened"] },
  >     { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" },
  >               "per_routine": { "usd_per_day": 15.0, "runs_per_hour": 6 } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'Review the diff.\n' > proposal/prompt.md
  $ printf '{"type":"object"}\n' > proposal/findings.schema.json

  $ mentatd routine add proposal | censor
  added pr-review ($TESTCASE_ROOT/config/mentat/routines/pr-review)
  digest $DIGEST1
  webhook POST /ingress/github/$DIGEST2 (fresh URL; update GitHub settings)
  webhook secret minted at $TESTCASE_ROOT/config/mentat/routines/pr-review/secrets/webhook; set it on the GitHub hook

  $ cp config/mentat/routines/pr-review/secrets/webhook secret.before
  $ cp config/mentat/routines/pr-review/ingress.id id.before

  $ mentatd routine rotate-secret pr-review | censor
  rotated webhook secret at $TESTCASE_ROOT/config/mentat/routines/pr-review/secrets/webhook
  webhook POST /ingress/github/$DIGEST (URL unchanged; set the new secret on the GitHub hook now — the old one no longer verifies)

The secret changed; the ingress id — the webhook URL — did not.

  $ cmp -s secret.before config/mentat/routines/pr-review/secrets/webhook || echo rotated
  rotated
  $ cmp id.before config/mentat/routines/pr-review/ingress.id && echo url-unchanged
  url-unchanged

The routine still loads whole: same digest, same state.

  $ mentatd routine list | censor
  NAME       DIGEST            STATE    LAST
  pr-review  $DIGEST  enabled  -

A missing routine is refused loudly.

  $ mentatd routine rotate-secret missing 2>&1
  mentat: load: $TESTCASE_ROOT/config/mentat/routines/missing: no routine named missing
  [1]

A routine without a webhook arm has no secret to rotate.

  $ mkdir cli-proposal
  $ cat > cli-proposal/routine.json <<'EOF'
  > { "routine": 1, "name": "cli-review",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'Review the diff.\n' > cli-proposal/prompt.md
  $ printf '{"type":"object"}\n' > cli-proposal/findings.schema.json
  $ mentatd routine add cli-proposal | censor
  added cli-review ($TESTCASE_ROOT/config/mentat/routines/cli-review)
  digest $DIGEST
  $ mentatd routine rotate-secret cli-review 2>&1
  mentat: routine cli-review has no github_webhook trigger, so there is no webhook secret to rotate
  [2]
