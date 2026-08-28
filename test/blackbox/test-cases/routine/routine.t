The routine cone round-trips: `add` validates a proposal and installs it under
the routine's own name, minting the webhook identity once; `list`, `status`,
and `runs` render the roster and the (empty) durable record; `remove` deletes
the configuration. No workspace, store, or network is touched.

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

The first add mints the ingress URL and the webhook secret.

  $ mentatd routine add proposal | censor
  added pr-review ($TESTCASE_ROOT/config/mentat/routines/pr-review)
  digest $DIGEST1
  webhook POST /ingress/github/$DIGEST2 (fresh URL; update GitHub settings)
  webhook secret minted at $TESTCASE_ROOT/config/mentat/routines/pr-review/secrets/webhook; set it on the GitHub hook

Re-adding replaces the policy files and keeps the identity: the URL is not
fresh and the secret is not re-minted, so owner edits never move the webhook
URL.

  $ mentatd routine add proposal | censor
  added pr-review ($TESTCASE_ROOT/config/mentat/routines/pr-review)
  digest $DIGEST1
  webhook POST /ingress/github/$DIGEST2

  $ mentatd routine list | censor
  NAME       DIGEST            STATE    LAST
  pr-review  $DIGEST  enabled  -

  $ mentatd routine status | censor
  pr-review
    state: enabled
    digest: $DIGEST
    spend 24h: 0.00 usd of 15.00
    runs 1h: 0 of 6
    last: no receipts

On empty state a routine has no runs to show.

  $ mentatd routine runs pr-review

A bare fire has nothing to review — every version-1 routine reviews pull
requests — so the verb asks for a delivery or a sweep (fire.t drives the
full pipeline).

  $ mentatd routine fire pr-review 2>&1
  mentat: routine pr-review reviews pull requests and a bare fire has nothing to review; use --event FILE or --sweep
  [2]

`remove` deletes the configuration — secrets and webhook identity included.
No state was recorded here, so nothing is named as kept.

  $ mentatd routine remove pr-review
  removed pr-review ($TESTCASE_ROOT/config/mentat/routines/pr-review)
  $ mentatd routine list
  $ mentatd routine runs pr-review 2>&1
  mentat: load: $TESTCASE_ROOT/config/mentat/routines/pr-review: no routine named pr-review
  [1]
