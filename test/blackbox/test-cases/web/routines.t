The routines dashboard: mentatd's web mount serves the needs-me-first page
at /routines — attention items above the fold, the routine record below —
with every value read per request from the roster, the receipt logs, and
the run fences. This drives the real daemon over HTTP: routines installed
and receipts recorded while it runs render at the next request, with no
restart and no cached projection.

  $ use_trusted_workspace
  $ export MENTAT_DAEMON_MAX_IDLE=300
  $ trap stop_daemon EXIT

  $ mentatd --web >web.out 2>&1 &
  $ MENTAT_DAEMON_PID=$!
  $ wait_for_file "$XDG_DATA_HOME/mentat/daemon/daemon.json"
  $ for _ in $(seq 1 100); do grep -q 'mentat web: open' web.out && break; sleep 0.1; done
  $ URL=$(sed -n 's/^mentat web: open //p' web.out)
  $ PORT=$(printf '%s' "$URL" | sed -E 's#.*127\.0\.0\.1:([0-9]+)/.*#\1#')
  $ BASE="http://127.0.0.1:$PORT"
  $ curl -sS -c jar -o /dev/null "$URL"

The page rides the same cookie gate as the rest of the mount.

  $ curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/routines"
  401

A node with no routines says so plainly.

  $ curl -sS -b jar "$BASE/routines" | grep -o 'No routines are installed[^<]*'
  No routines are installed. Install one with mentatd routine add.

Install a webhook routine and a cli routine, and break a third — all while
the daemon runs.

  $ mkdir p-quiet
  $ cat > p-quiet/routine.json <<'EOF'
  > { "routine": 1, "name": "a-quiet",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "github_webhook", "events": ["pull_request.opened"] } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" },
  >               "per_routine": { "usd_per_day": 15.0, "runs_per_hour": 6 } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'Review the diff.\n' > p-quiet/prompt.md
  $ printf '{"type":"object"}\n' > p-quiet/findings.schema.json
  $ mentatd routine add p-quiet >/dev/null

  $ mkdir p-attention
  $ cat > p-attention/routine.json <<'EOF'
  > { "routine": 1, "name": "z-attention",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'Review the diff.\n' > p-attention/prompt.md
  $ printf '{"type":"object"}\n' > p-attention/findings.schema.json
  $ mentatd routine add p-attention >/dev/null

  $ mkdir p-broken
  $ sed 's/z-attention/m-broken/' p-attention/routine.json > p-broken/routine.json
  $ cp p-attention/prompt.md p-attention/findings.schema.json p-broken/
  $ mentatd routine add p-broken >/dev/null
  $ printf 'not json\n' > "$XDG_CONFIG_HOME/mentat/routines/m-broken/routine.json"

Record one failed run for the cli routine by hand: the receipt bytes are
this build's own codec, so writing them is writing what the pipeline would
have — a spawned line, the reap that settled nothing, and the identity's
failed alert.

  $ DIGEST=$(mentatd routine list | awk '$1 == "z-attention" {print $2}')
  $ NOW=$(date +%s)
  $ RECEIPTS="$XDG_STATE_HOME/mentat/routines/z-attention/receipts.jsonl"
  $ mkdir -p "$(dirname "$RECEIPTS")"
  $ printf '{"kind":"disposition","at":%s,"identity":"cli:%s:boom","digest":"%s","disposition":"spawned","session":"c-1111111111111111"}\n' "$NOW" "$DIGEST" "$DIGEST" >> "$RECEIPTS"
  $ printf '{"kind":"disposition","at":%s,"identity":"cli:%s:boom","digest":"%s","disposition":"reaped","session":"c-1111111111111111","exit":255,"head":"missing","usage":{},"cause":"exited"}\n' "$NOW" "$DIGEST" "$DIGEST" >> "$RECEIPTS"
  $ printf '{"kind":"alert","at":%s,"identity":"cli:%s:boom","digest":"%s","transition":"failed","window":"identity"}\n' "$NOW" "$DIGEST" "$DIGEST" >> "$RECEIPTS"

The next request renders it all, needs-me first: the failed run leads
whatever the roster order says, the broken routine is a named refusal, and
only then comes the record — the loadable routines in roster order.

  $ PAGE=$(curl -sS -b jar "$BASE/routines")
  $ printf '%s\n' "$PAGE" | grep -oE 'class="item [a-z]+"|The record|class="name">[a-z-]+'
  class="item failed"
  class="item broken"
  The record
  class="name">a-quiet
  class="name">z-attention

The failed item carries the alert's judgment and the attach path.

  $ printf '%s\n' "$PAGE" | grep -o 'settled without a publishable outcome'
  settled without a publishable outcome
  $ printf '%s\n' "$PAGE" | grep -o 'href="/session/c-1111111111111111"' | head -1
  href="/session/c-1111111111111111"

The record rows mirror the status fold — spend and rate against their
fences, the last disposition, and the webhook routine's ingress path,
honest about the unbound listener.

  $ printf '%s\n' "$PAGE" | grep -o 'spend 24h: 0.00 usd of 15.00'
  spend 24h: 0.00 usd of 15.00
  $ printf '%s\n' "$PAGE" | grep -o 'runs 1h: 0 of 6'
  runs 1h: 0 of 6
  $ printf '%s\n' "$PAGE" | grep -o 'last: reaped:255'
  last: reaped:255
  $ printf '%s\n' "$PAGE" | grep -cE 'ingress: POST /ingress/github/[0-9a-f]{32} \(unbound\)'
  1
