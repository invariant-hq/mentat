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
  $ mentatd charter add proposal >/dev/null
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
  $ mentatd charter fire pr-review --event event-stale.json | censor
  superseded github:acme/widgets#7@$DIGEST:head
  $ wait_fake_server
  $ RECEIPTS="$PWD/state/mentat/charters/pr-review/receipts.jsonl"
  $ grep -c '"disposition":"superseded"' "$RECEIPTS"
  1

Exhaust the rate window by hand: one spawned receipt under the current
digest inside the trailing hour. The receipt bytes are this build's own
codec, so writing them directly is writing what the pipeline would have.

  $ digest=$(mentatd charter list | awk 'NR==2 {print $2}')
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
  $ mentatd charter fire pr-review --event event-fresh.json | censor
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
  $ mentatd charter fire pr-review --event event-later.json | censor
  fenced github:acme/widgets#9@$DIGEST:head: runs_per_hour
  $ wait_fake_server
  $ grep -c '"kind":"alert"' "$RECEIPTS"
  1
  $ grep -c '"transition":"fenced"' alerts.log
  1

The verb's own ladder. A fire without the read credential is refused before
any receipt — the pipeline cannot gate what it cannot observe.

  $ rm "$CDIR/secrets/read-token"
  $ mentatd charter fire pr-review --event event-fresh.json 2>&1 | censor
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
  $ mentatd charter add hookless >/dev/null
  $ mentatd charter fire hookless --event event-fresh.json 2>&1
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
  $ mentatd charter add webhookless >/dev/null
  $ mentatd charter fire webhookless --event event-fresh.json 2>&1
  mentat: charter webhookless has no github_webhook trigger; --event and --sweep replay webhook deliveries
  [2]
  $ mentatd charter fire webhookless --sweep 2>&1
  mentat: charter webhookless has no github_webhook trigger; --event and --sweep replay webhook deliveries
  [2]

--event and --sweep are one choice, and a bare fire has nothing to review.

  $ mentatd charter fire pr-review --event event-fresh.json --sweep 2>&1
  mentat: choose one of --event or --sweep
  [2]
  $ mentatd charter fire pr-review 2>&1
  mentat: charter pr-review reviews pull requests and a bare fire has nothing to review; use --event FILE or --sweep
  [2]

The webhook default: a charter metering nothing per-charter still fences at
6 runs per hour, because --event and --sweep process webhook-shaped
deliveries — their rate is set by whoever opens pull requests, so an
unfenced webhook charter cannot exist by omission. Six in-window spawns are
seeded; the seventh admissible delivery is fenced.

  $ mkdir nometer
  $ cat > nometer/charter.json <<'EOF'
  > { "charter": 1, "name": "nometer",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [
  >     { "kind": "github_webhook", "events": ["pull_request.opened"] },
  >     { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "5m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'p\n' > nometer/prompt.md
  $ printf '{"type":"object"}\n' > nometer/findings.schema.json
  $ mentatd charter add nometer >/dev/null
  $ NDIR="$PWD/config/mentat/charters/nometer"
  $ printf 'test-read-token\n' > "$NDIR/secrets/read-token"
  $ chmod 600 "$NDIR/secrets/read-token"
  $ NRECEIPTS="$PWD/state/mentat/charters/nometer/receipts.jsonl"
  $ ndigest=$(mentatd charter list | awk '$1 == "nometer" {print $2}')
  $ mkdir -p "$(dirname "$NRECEIPTS")"
  $ for i in 1 2 3 4 5 6; do
  >   printf '{"kind":"disposition","at":%s,"identity":"cli:%s:seed-%s","digest":"%s","disposition":"spawned","session":"c-000000000000000%s"}\n' "$(date +%s)" "$ndigest" "$i" "$ndigest" "$i" >> "$NRECEIPTS"
  > done
  $ seventh=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  $ cat > event-seventh.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 14, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$seventh" },
  >     "base": { "ref": "main" } } }
  > EOF
  $ cat > github-seventh.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/14 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$seventh"}}}}
  > EOF
  $ start_fake_server github-seventh.jsonl capture-seventh gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentatd charter fire nometer --event event-seventh.json | censor
  fenced github:acme/widgets#14@$DIGEST:head: runs_per_hour
  $ wait_fake_server
  $ mentatd charter status nometer | grep 'runs 1h'
    runs 1h: 6 of 6

Refusals never claim, so an event re-enters when its circumstances change.
A draft head swept once is skipped — and re-decided on every pass: marked
ready, the same head passes the gate and reaches the fence; the window
freed, it drives on to the checkout. The receipts poison nothing.

  $ printf 'test-read-token\n' > "$CDIR/secrets/read-token"
  $ chmod 600 "$CDIR/secrets/read-token"
  $ drafthead=ffffffffffffffffffffffffffffffffffffffff
  $ cat > listing-draft.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 12, "draft": true, "author_association": "OWNER", "head": {"sha": "$drafthead"}, "base": {"ref": "main"}}]}}
  > EOF
  $ start_fake_server listing-draft.jsonl capture-draft gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentatd charter fire pr-review --sweep | censor
  skipped github:acme/widgets#12@$DIGEST:head: draft pull requests are not admitted
  $ wait_fake_server
  $ cat > listing-ready.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 12, "draft": false, "author_association": "OWNER", "head": {"sha": "$drafthead"}, "base": {"ref": "main"}}]}}
  > EOF
  $ start_fake_server listing-ready.jsonl capture-ready gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentatd charter fire pr-review --sweep | censor
  fenced github:acme/widgets#12@$DIGEST:head: runs_per_hour
  $ wait_fake_server

Free the window — the seeded spawn moves two hours back — and the same head
passes the fence and commits: the claim is taken and the pipeline reaches
the checkout, which fails loudly against a dead remote. The fenced receipts
did not poison re-admission; only the run-claim dedups.

  $ grep -v '"disposition":"spawned"' "$RECEIPTS" > receipts.rewritten
  $ mv receipts.rewritten "$RECEIPTS"
  $ printf '{"kind":"disposition","at":%s,"identity":"cli:%s:seed","digest":"%s","disposition":"spawned","session":"c-0000000000000000"}\n' "$(($(date +%s) - 7200))" "$digest" "$digest" >> "$RECEIPTS"
  $ start_fake_server listing-ready.jsonl capture-freed gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ export MENTAT_CHARTER_GIT_URL="$PWD/no-such-remote"
  $ mentatd charter fire pr-review --sweep 2>&1 | censor | sed -e 's/checkout: .*/checkout: (git error)/' -e 's/^mentat: git .*/mentat: (git error)/'
  refused github:acme/widgets#12@$DIGEST:head: checkout: (git error)
  mentat: (git error)
  [1]
  $ wait_fake_server
  $ grep -c '"disposition":"refused"' "$RECEIPTS"
  1

A broken output schema refuses before any spend: the recorded contract is
decoded and pre-flighted before the run-claim, so the refusal claims
nothing, provisions nothing, and mints no session — the head re-enters
freely once the charter is repaired. (Breaking the schema moves the policy
digest, so this delivery is a fresh identity under the edited policy.)

  $ ls "$PWD/state/mentat/charters/pr-review/events" | wc -l | tr -d ' '
  1
  $ ls "$HOME/.cache/mentat/charters/pr-review/runs" | wc -l | tr -d ' '
  1
  $ printf 'not json\n' > "$CDIR/findings.schema.json"
  $ start_fake_server github-fresh.jsonl capture-badschema gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentatd charter fire pr-review --event event-fresh.json 2>&1 | censor | sed -e 's/not valid JSON: .*/not valid JSON: (parse error)/' -e '/^File "-"/d'
  refused github:acme/widgets#8@$DIGEST:head: output schema: not valid JSON: (parse error)
  mentat: output schema: not valid JSON: (parse error)
  [1]
  $ wait_fake_server
  $ grep -c '"disposition":"refused"' "$RECEIPTS"
  2
  $ ls "$PWD/state/mentat/charters/pr-review/events" | wc -l | tr -d ' '
  1
  $ ls "$HOME/.cache/mentat/charters/pr-review/runs" | wc -l | tr -d ' '
  1
  $ ls "$XDG_DATA_HOME/mentat/sessions" | wc -l | tr -d ' '
  0
