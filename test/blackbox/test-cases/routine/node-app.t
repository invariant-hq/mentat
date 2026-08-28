The App-level ingress through the resident node: one more resolver source
beside the per-routine ids — the App's own ingress id, verifying against
the App's webhook secret — and routing by the verified payload's
repository to App-mode webhook routines only. Every routine here is
disabled, so each routed delivery leaves its durable delivery-plus-skipped
receipt pair without spawning anything: the receipts are the routing
proof, and the disabled state is the cheapest honest observer. A PAT
routine watching the same repository is deliberately excluded from App
routing — it has its own id and webhook — and its own id keeps answering
beside the App's.

The credential home; no network call ever happens in this test, so the
recorded base is the public default.

  $ APPDIR="$XDG_CONFIG_HOME/mentat/github-app"
  $ mkdir -p "$APPDIR" && chmod 700 "$APPDIR"
  $ cat > "$APPDIR/app.json" <<'EOF'
  > {"github_app":1,"id":12345,"slug":"mentat-review-test","name":"mentat-review-test","client_id":"Iv1.test","html_url":"https://github.com/apps/mentat-review-test","api_base":"https://api.github.com","created_at":"2026-08-28T00:00:00Z"}
  > EOF
  $ printf 'dummy key never read here\n' > "$APPDIR/private-key.pem"
  $ printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$APPDIR/webhook-secret"
  $ printf 'feedfacefeedfacefeedfacefeedface\n' > "$APPDIR/ingress.id"
  $ chmod 600 "$APPDIR"/app.json "$APPDIR"/private-key.pem "$APPDIR"/webhook-secret "$APPDIR"/ingress.id
  $ APP_ID=$(cat "$APPDIR/ingress.id")
  $ APP_SECRET=$(cat "$APPDIR/webhook-secret")

The daemon, ingress on an ephemeral loopback port.

  $ trap stop_daemon EXIT
  $ export MENTAT_DAEMON_MAX_IDLE=300
  $ mentatd --ingress-port 0 >daemon-serve.out 2>&1 &
  $ MENTAT_DAEMON_PID=$!
  $ wait_for_file "$XDG_DATA_HOME/mentat/daemon/daemon.json"
  $ IPORT=$(sed -n 's/^mentatd ingress: 127\.0\.0\.1://p' daemon-serve.out)
  $ BASE="http://127.0.0.1:$IPORT"

Three disabled webhook routines: two App-mode (one per repository) and one
PAT routine sharing the widgets repository. The PAT routine's identity is
minted by the documented in-place re-add after its token lands — an add
under a loaded App home mints nothing.

  $ routine_json () {
  >   printf '{ "routine": 1, "name": "%s", "enabled": false,
  >   "workspace": { "repo": "%s" },
  >   "trigger": [ { "kind": "github_webhook", "events": ["pull_request.opened"] } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "5m" } },
  >   "publish": { "github": "review-threads" } }' "$1" "$2"
  > }
  $ for r in widgets-app:acme/widgets gears-app:acme/gears pat-review:acme/widgets; do
  >   name="${r%%:*}"; repo="${r#*:}"
  >   mkdir "prop-$name"
  >   routine_json "$name" "$repo" > "prop-$name/routine.json"
  >   printf 'Review.\n' > "prop-$name/prompt.md"
  >   printf '{"type":"object"}\n' > "prop-$name/findings.schema.json"
  >   mentatd routine add "prop-$name" >/dev/null
  > done
  $ PDIR="$XDG_CONFIG_HOME/mentat/routines/pat-review"
  $ mkdir -p "$PDIR/secrets" && chmod 700 "$PDIR/secrets"
  $ printf 'test-read-token\n' > "$PDIR/secrets/read-token"
  $ chmod 600 "$PDIR/secrets/read-token"
  $ mentatd routine add "$PDIR" >/dev/null
  $ PAT_ID=$(cat "$PDIR/ingress.id")
  $ PAT_SECRET=$(cat "$PDIR/secrets/webhook")
  $ mentatd routine list | censor
  NAME         DIGEST            STATE     AUTH  LAST
  gears-app    $DIGEST1  disabled  app   -
  pat-review   $DIGEST2  disabled  pat   -
  widgets-app  $DIGEST3  disabled  app   -

A pull_request delivery signed with the App secret, addressed to the App
id: 202, routed by its repository member to the App-mode routine watching
acme/widgets alone — the PAT routine watching the same repository receipts
nothing, because it has its own id and webhook.

  $ cat > widgets.json <<'EOF'
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 7, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  >     "base": { "ref": "main" } } }
  > EOF
  $ SIG=$(mentat_cram hmac-sha256 "$APP_SECRET" widgets.json)
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-Hub-Signature-256: sha256=$SIG" --data-binary @widgets.json \
  >   "$BASE/ingress/github/$APP_ID"
  202
  $ WRECEIPTS="$PWD/state/mentat/routines/widgets-app/receipts.jsonl"
  $ grep -c '"kind":"delivery"' "$WRECEIPTS"
  1
  $ grep -c '"disposition":"skipped"' "$WRECEIPTS"
  1
  $ test ! -e "$PWD/state/mentat/routines/pat-review/receipts.jsonl" && echo pat-untouched
  pat-untouched
  $ test ! -e "$PWD/state/mentat/routines/gears-app/receipts.jsonl" && echo gears-untouched
  gears-untouched

The same App id serves every installed repository: a gears delivery routes
to the gears routine, widgets rows unchanged.

  $ sed 's|acme/widgets|acme/gears|' widgets.json > gears.json
  $ SIG=$(mentat_cram hmac-sha256 "$APP_SECRET" gears.json)
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-Hub-Signature-256: sha256=$SIG" --data-binary @gears.json \
  >   "$BASE/ingress/github/$APP_ID"
  202
  $ grep -c '"kind":"delivery"' "$PWD/state/mentat/routines/gears-app/receipts.jsonl"
  1
  $ grep -c '"kind":"delivery"' "$WRECEIPTS"
  1

A delivery for a repository no App routine watches — the owner installed
the App more widely than they routine — is a 202 and a trace note, not an
error and not a receipt.

  $ sed 's|acme/widgets|acme/unwatched|' widgets.json > unwatched.json
  $ SIG=$(mentat_cram hmac-sha256 "$APP_SECRET" unwatched.json)
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-Hub-Signature-256: sha256=$SIG" --data-binary @unwatched.json \
  >   "$BASE/ingress/github/$APP_ID"
  202
  $ grep -c 'app ingress: no routine watches acme/unwatched' daemon-serve.out
  1

A ping on the App id is answered and never receipted; a bad signature is a
content-free 401; an unknown id is a 404.

  $ printf '{"zen":"keep it simple"}' > ping.json
  $ SIG=$(mentat_cram hmac-sha256 "$APP_SECRET" ping.json)
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: ping" \
  >   -H "X-Hub-Signature-256: sha256=$SIG" --data-binary @ping.json \
  >   "$BASE/ingress/github/$APP_ID"
  202
  $ grep -c 'app ingress: ignoring ping delivery' daemon-serve.out
  1
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-Hub-Signature-256: sha256=deadbeef" --data-binary @widgets.json \
  >   "$BASE/ingress/github/$APP_ID"
  401
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-Hub-Signature-256: sha256=$SIG" --data-binary @widgets.json \
  >   "$BASE/ingress/github/00000000000000000000000000000000"
  404

The PAT routine's own id keeps answering beside the App's, against its own
secret — the two sources coexist.

  $ SIG=$(mentat_cram hmac-sha256 "$PAT_SECRET" widgets.json)
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-Hub-Signature-256: sha256=$SIG" --data-binary @widgets.json \
  >   "$BASE/ingress/github/$PAT_ID"
  202
  $ grep -c '"kind":"delivery"' "$PWD/state/mentat/routines/pat-review/receipts.jsonl"
  1
