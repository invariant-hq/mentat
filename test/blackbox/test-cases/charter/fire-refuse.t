The fire pipeline's refusal arms: a stale head is receipted superseded, a
tripped rate fence refuses with exactly one alert per window and one notify
hook firing, and the verb's own ladder refuses a fire the charter's trigger
list does not admit or the credentials cannot serve. No provider, checkout,
or run is ever reached.

A charter metering one run per hour, alerting on fenced through a hook that
appends each event line to a log.

  $ cat > hook.sh <<EOF
  > #!/bin/sh
  > cat >> "$PWD/alerts.log"
  > EOF
  $ chmod +x hook.sh
  $ mkdir proposal
  $ cat > proposal/charter.json <<EOF
  > { "charter": 1, "name": "pr-review",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [
  >     { "kind": "github_webhook", "events": ["pull_request.opened"] },
  >     { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "5m" },
  >               "per_charter": { "runs_per_hour": 1 } },
  >   "publish": { "github": "review-threads" },
  >   "notify": { "on": ["fenced"], "command": ["$PWD/hook.sh"] } }
  > EOF
  $ printf 'Review the diff.\n' > proposal/prompt.md
  $ printf '{"type":"object"}\n' > proposal/findings.schema.json
  $ mentat charter add proposal >/dev/null
  $ CDIR="$PWD/config/mentat/charters/pr-review"
  $ printf 'test-read-token\n' > "$CDIR/secrets/read-token"
  $ chmod 600 "$CDIR/secrets/read-token"

A delivery whose head the pull request has moved past is superseded at the
gate — the injected current-head read answers a different commit — and
never claims, fences, or spawns.

  $ stale=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  $ current=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  $ cat > event-stale.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 7, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$stale" },
  >     "base": { "ref": "main" } } }
  > EOF
  $ cat > github-stale.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$current"}}}}
  > EOF
  $ start_fake_server github-stale.jsonl capture-stale gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentat charter fire pr-review --event event-stale.json | censor
  superseded github:acme/widgets#7@$DIGEST:head
  $ wait_fake_server
  $ RECEIPTS="$PWD/state/mentat/charters/pr-review/receipts.jsonl"
  $ grep -c '"disposition":"superseded"' "$RECEIPTS"
  1

Exhaust the rate window by hand: one spawned receipt under the current
digest inside the trailing hour. The receipt bytes are this build's own
codec, so writing them directly is writing what the pipeline would have.

  $ digest=$(mentat charter list | awk 'NR==2 {print $2}')
  $ printf '{"kind":"disposition","at":%s,"identity":"cli:%s:seed","digest":"%s","disposition":"spawned","session":"c-0000000000000000"}\n' "$(date +%s)" "$digest" "$digest" >> "$RECEIPTS"

The next admissible delivery is fenced after its delivery receipt: the
disposition names the meter, the first trip in the window alerts exactly
once, and the hook heard exactly one structured event.

  $ fresh=cccccccccccccccccccccccccccccccccccccccc
  $ cat > event-fresh.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 8, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$fresh" },
  >     "base": { "ref": "main" } } }
  > EOF
  $ cat > github-fresh.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/8 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$fresh"}}}}
  > EOF
  $ start_fake_server github-fresh.jsonl capture-fresh gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentat charter fire pr-review --event event-fresh.json | censor
  fenced github:acme/widgets#8@$DIGEST:head: runs_per_hour
  $ wait_fake_server
  $ grep -c '"disposition":"fenced"' "$RECEIPTS"
  1
  $ grep -c '"kind":"alert"' "$RECEIPTS"
  1
  $ mentat_cram json .transition alerts.log
  fenced

A second trip in the same window is receipted silently: no second alert
line, no second hook firing.

  $ later=dddddddddddddddddddddddddddddddddddddddd
  $ cat > event-later.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 9, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$later" },
  >     "base": { "ref": "main" } } }
  > EOF
  $ cat > github-later.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/9 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$later"}}}}
  > EOF
  $ start_fake_server github-later.jsonl capture-later gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentat charter fire pr-review --event event-later.json | censor
  fenced github:acme/widgets#9@$DIGEST:head: runs_per_hour
  $ wait_fake_server
  $ grep -c '"kind":"alert"' "$RECEIPTS"
  1
  $ grep -c '"transition":"fenced"' alerts.log
  1

The verb's own ladder. A fire without the read credential is refused before
any receipt — the pipeline cannot gate what it cannot observe.

  $ rm "$CDIR/secrets/read-token"
  $ mentat charter fire pr-review --event event-fresh.json 2>&1 | censor
  mentat: fire needs the GitHub read credential at $TESTCASE_ROOT/config/mentat/charters/pr-review/secrets/read-token (a fine-grained PAT with read access to acme/widgets)
  [1]

A charter without a cli trigger arm does not admit hand fires at all; one
without a webhook arm has no deliveries for --event or --sweep to replay.

  $ mkdir hookless webhookless
  $ cat > hookless/charter.json <<'EOF'
  > { "charter": 1, "name": "hookless",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "github_webhook",
  >                  "events": ["pull_request.opened"] } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "5m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'p\n' > hookless/prompt.md
  $ printf '{"type":"object"}\n' > hookless/findings.schema.json
  $ mentat charter add hookless >/dev/null
  $ mentat charter fire hookless --event event-fresh.json 2>&1
  mentat: charter hookless has no cli trigger arm; add {"kind": "cli"} to its trigger list to fire it by hand
  [2]
  $ cat > webhookless/charter.json <<'EOF'
  > { "charter": 1, "name": "webhookless",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "5m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'p\n' > webhookless/prompt.md
  $ printf '{"type":"object"}\n' > webhookless/findings.schema.json
  $ mentat charter add webhookless >/dev/null
  $ mentat charter fire webhookless --event event-fresh.json 2>&1
  mentat: charter webhookless has no github_webhook trigger; --event and --sweep replay webhook deliveries
  [2]
  $ mentat charter fire webhookless --sweep 2>&1
  mentat: charter webhookless has no github_webhook trigger; --event and --sweep replay webhook deliveries
  [2]

--event and --sweep are one choice, and --key belongs to neither.

  $ mentat charter fire pr-review --event event-fresh.json --sweep 2>&1
  mentat: choose one of --event or --sweep
  [2]
  $ mentat charter fire pr-review --sweep --key nightly 2>&1
  mentat: --key names a bare fire's identity; --event and --sweep carry their delivery's own
  [2]
