The GitHub App's owner surface, short of the browser flow (the manifest
and loopback pieces are unit-covered): the github verbs refuse cleanly with
no credential home; a fabricated home — provisioning is files, so writing
one by hand is the documented headless path — flips every mode surface to
app; PAT files win the mode back; the per-routine rotate refuses on an App
routine, naming the owner-level verb; and the doctor, repoint, and
rotate-secret run their network halves against a scripted GitHub fake,
with GitHub's hook config converging as a projection of the local files.

Without a credential home every github verb refuses, naming setup.

  $ mentatd github status
  app: not set up; run `mentatd github setup`
  [1]
  $ mentatd github repoint https://hooks.example.com 2>&1
  mentat: no GitHub App is set up; run `mentatd github setup` first
  [1]
  $ mentatd github rotate-secret 2>&1
  mentat: no GitHub App is set up; run `mentatd github setup` first
  [1]

A webhook routine installed with no App and no PAT files is mode none, and
its identity is minted as always (the PAT journey may still be chosen).

  $ mkdir proposal
  $ cat > proposal/routine.json <<'EOF'
  > { "routine": 1, "name": "pr-review",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [
  >     { "kind": "github_webhook", "events": ["pull_request.opened"] },
  >     { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "5m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ printf 'Review the diff.\n' > proposal/prompt.md
  $ printf '{"type":"object"}\n' > proposal/findings.schema.json
  $ mentatd routine add proposal | censor
  added pr-review ($TESTCASE_ROOT/config/mentat/routines/pr-review)
  digest $DIGEST1
  webhook POST /ingress/github/$DIGEST2 (fresh URL; update GitHub settings)
  webhook secret minted at $TESTCASE_ROOT/config/mentat/routines/pr-review/secrets/webhook; set it on the GitHub hook
  auth: none; run `mentatd github setup` or write secrets/read-token

The credential home, written by hand — atomic setup writes exactly these
files, and copying them onto a headless box is the documented path. The
fake GitHub server is started first so app.json can record its base.

  $ cat > doctor.jsonl <<'EOF'
  > {"expect": {"request_line": "GET /app HTTP/1.1"}, "http": {"status": 200, "json": {"slug": "mentat-review-test", "name": "mentat-review-test", "id": 12345}}}
  > {"expect": {"request_line": "GET /app/hook/config HTTP/1.1"}, "http": {"status": 200, "json": {"url": "https://unrouted.invalid/ingress/github/feedfacefeedfacefeedfacefeedface", "content_type": "json"}}}
  > {"expect": {"request_line": "GET /app/installations?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"id": 987, "account": {"login": "owner"}}]}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/installation HTTP/1.1"}, "http": {"status": 200, "json": {"id": 987}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/installation HTTP/1.1"}, "http": {"status": 200, "json": {"id": 987}}}
  > EOF
  $ start_fake_server doctor.jsonl capture-doctor gh-port
  $ BASE="http://127.0.0.1:$(cat gh-port)"
  $ APPDIR="$XDG_CONFIG_HOME/mentat/github-app"
  $ mkdir -p "$APPDIR" && chmod 700 "$APPDIR"
  $ cat > "$APPDIR/app.json" <<EOF
  > {"github_app":1,"id":12345,"slug":"mentat-review-test","name":"mentat-review-test","client_id":"Iv1.test","html_url":"https://github.com/apps/mentat-review-test","api_base":"$BASE","created_at":"2026-08-28T00:00:00Z"}
  > EOF
  $ cat > "$APPDIR/private-key.pem" <<'EOF'
  > -----BEGIN RSA PRIVATE KEY-----
  > MIIEpQIBAAKCAQEAvP8Hg58J/tD8yQLsdtJ7jbVlhtg8AFSOLayJEhcondf3cp5i
  > cokncJ25WWsBAequ9Q26URDQEg4ml8qNXLRzHGyFefGu65uAh+HzqInHaFzTAJmH
  > K3W5LTy/7qTMT5VSGadfOH7wi7Qs1WqpKjctIMeFTDuVBVKSA9QE71+CnQDZnQ5G
  > 7rEhyesXL1NWODJuFCpbJNugutgskgaXHWQf8+36K4NTSTc/Z0dGwNOnCJrDaRco
  > j00ugo1fKJrQ6Mo8IHt9t1/KI23fA0O1RhxgbbdV9cqqh4ZdHUiyIutnJhajZP5r
  > x7w8JBn/EpNszNakr2raHk9H0YNsCCeoT+RiZQIDAQABAoIBAAsY3g//qYaALr4+
  > cR7R9uYSya+8UxuW22lO+UEUwd0GG7YBGu6MOJgKHs0OCsyvbbn0UNARO2e6qSVJ
  > A/oL8LqxcY3qimGJq3yZtbpGlWzpObd44aEEOXewmo7F4jw7BuDRknZUAnDwMaC6
  > BvhJre6VNdxhyZB628QknGySEFktDr0SpsehYY2Z4BZwQGY00bysEHVeHJKU7rNa
  > 1wE+JzadpHBQxdORRlT1G01nkWhJ55tRG2D6benbl35dmz0fgr15KIDtsyCFItmP
  > asnozgEC6GLRYXyIYpotFQYYTWAf5RlKOGYPDW385I8VjqCB7jTXt7+SBIePEZ/e
  > DTw0fTECgYEA8cJrXvN5amwzEO+Okbb5tt8EG1Zf4B8u2oJvFDdDH4kOIof4b0yR
  > ZDIInouf4wKz6icyRhlpamM3UB3mixClqyN+vydVGRnl1RdfBQopblAdbYWsKzCo
  > wwDhEgfOiEwuMEMA9wpHswqwPUVVge7lWD9AuGXncftY0mZustDuhtUCgYEAyCD5
  > MJ7oI2JkPPrJIV4eqFm/KcCCFmRxqGSy6bobAY1+lROCaPqNFPF1TW/hu/jGdnNb
  > 6lrZKvhYfcc5EGnog1REEWkG6Zeou/HaE42ndHQaT6lDrqPUL17WA1c8mDdEA6qM
  > SYdxw63HgENw3OAcqOLtlLWFj32c6Iwx6JyLVVECgYEA4eHmkkvoqK+5stwxGCKf
  > BOcwnh5A7FYWX+E4yemsVJ2o0Ei8rbkbq0M4XHJWjDNtSJ0g0vBRVy6mcrvNOSfv
  > sowyk4W7c/2HiWcRx9KrzT8bj8YyjBQlyjVbFY6nwR90lHE2SJuZTEbzTfwnHYTJ
  > Un+fB+tmqU/PuJ4uVfLyupUCgYEAok8byvMWEpyZ71r2BLnw41jmUVZwKvkLtSb2
  > c9kcTgYTw5QvEDUkdvfdyxASZAE/9JFa2pcTymXgXyJUhZtfmCOfkP89O/ZkQwnD
  > dFhOl4QSUslUuy7jyAeCSvNVkZ5A6zhGztuqyKkIRF5uCrU4iUCCrzkJOXcG6xPI
  > 5n8QAgECgYEAxODOXI4GtDL1ijdHfoorh9cUMDw29PGGz2D3RiRAdKC7g2i1i9KL
  > /wal5UMZNNj0keWxs09CHwa/uX08SHlyeKBRr0tL90uqCrkJP/B3E0dqj0dUm55i
  > wKI8NYXfoA68SkCmKvHC6cpC/lE2eLobuGS4uz8aXdNCIianuExAX9o=
  > -----END RSA PRIVATE KEY-----
  > EOF
  $ printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$APPDIR/webhook-secret"
  $ printf 'feedfacefeedfacefeedfacefeedface\n' > "$APPDIR/ingress.id"
  $ chmod 600 "$APPDIR"/app.json "$APPDIR"/private-key.pem "$APPDIR"/webhook-secret "$APPDIR"/ingress.id

The home in place, the same routine is an App routine on every surface —
no token written, no webhook identity consulted.

  $ mentatd routine list | censor
  NAME       DIGEST            STATE    AUTH  LAST
  pr-review  $DIGEST  enabled  app   -
  $ mentatd routine status pr-review | censor | head -4
  pr-review
    state: enabled
    digest: $DIGEST
    auth: GitHub App mentat-review-test (posts as mentat-review-test[bot])

A second webhook routine added under the App mints nothing: there is
nothing to paste into GitHub settings, and the add points at the doctor.

  $ mkdir proposal2
  $ sed 's/pr-review/second-review/' proposal/routine.json > proposal2/routine.json
  $ cp proposal/prompt.md proposal2/prompt.md
  $ cp proposal/findings.schema.json proposal2/findings.schema.json
  $ mentatd routine add proposal2 | censor
  added second-review ($TESTCASE_ROOT/config/mentat/routines/second-review)
  digest $DIGEST
  auth: GitHub App mentat-review-test (posts as mentat-review-test[bot])
  verify the installation covers acme/widgets: mentatd github status
  $ test -e config/mentat/routines/second-review/ingress.id || echo no-ingress-id
  no-ingress-id

The per-routine rotate refuses on an App routine — a per-routine verb must
not silently act on owner-level state.

  $ mentatd routine rotate-secret pr-review 2>&1
  mentat: routine pr-review authenticates through the GitHub App, whose webhook secret is owner-level; use `mentatd github rotate-secret`
  [2]

The doctor, network half against the scripted fake: the App answers under
a fresh JWT, the live hook config matches what the local files derive (the
unrouted placeholder), the installation covers the watched repository.

  $ mentatd github status | censor
  app: mentat-review-test (id 12345) reachable; posts as mentat-review-test[bot]
  webhook: unrouted (placeholder); deliveries start after `mentatd github repoint <public-url>`
  installations: 1
  pr-review  acme/widgets  app  installation 987 ok
  second-review  acme/widgets  app  installation 987 ok
  $ wait_fake_server

Wait: the doctor asked one installation lookup per App routine.

  $ cat > doctor2.jsonl <<'EOF'
  > {"expect": {"request_line": "GET /app HTTP/1.1"}, "http": {"status": 200, "json": {"slug": "mentat-review-test", "name": "mentat-review-test", "id": 12345}}}
  > {"expect": {"request_line": "GET /app/hook/config HTTP/1.1"}, "http": {"status": 200, "json": {"url": "https://unrouted.invalid/ingress/github/feedfacefeedfacefeedfacefeedface", "content_type": "json"}}}
  > {"expect": {"request_line": "GET /app/installations?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"id": 987, "account": {"login": "owner"}}]}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/installation HTTP/1.1"}, "http": {"status": 200, "json": {"id": 987}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/installation HTTP/1.1"}, "http": {"status": 404, "json": {"message": "Not Found"}}}
  > EOF

An uninstalled repository is flagged with the install page, and the doctor
exits 1.

  $ start_fake_server doctor2.jsonl capture-doctor2 gh-port
  $ BASE2="http://127.0.0.1:$(cat gh-port)"
  $ sed "s|\"api_base\":\"[^\"]*\"|\"api_base\":\"$BASE2\"|" "$APPDIR/app.json" > app.json.new
  $ mv app.json.new "$APPDIR/app.json" && chmod 600 "$APPDIR/app.json"
  $ mentatd github status
  app: mentat-review-test (id 12345) reachable; posts as mentat-review-test[bot]
  webhook: unrouted (placeholder); deliveries start after `mentatd github repoint <public-url>`
  installations: 1
  pr-review  acme/widgets  app  installation 987 ok
  second-review  acme/widgets  app  not installed; install it: https://github.com/apps/mentat-review-test/installations/new
  [1]
  $ wait_fake_server

repoint writes the local file first, then upserts the whole hook config
derived from it — URL from public-url plus ingress.id, secret from the
stored webhook secret.

  $ cat > repoint.jsonl <<'EOF'
  > {"expect": {"request_line": "PATCH /app/hook/config HTTP/1.1", "body_contains": ["https://hooks.example.com/ingress/github/feedfacefeedfacefeedfacefeedface", "\"content_type\":\"json\"", "0123456789abcdef"]}, "http": {"status": 200, "json": {}}}
  > EOF
  $ start_fake_server repoint.jsonl capture-repoint gh-port
  $ BASE3="http://127.0.0.1:$(cat gh-port)"
  $ sed "s|\"api_base\":\"[^\"]*\"|\"api_base\":\"$BASE3\"|" "$APPDIR/app.json" > app.json.new
  $ mv app.json.new "$APPDIR/app.json" && chmod 600 "$APPDIR/app.json"
  $ mentatd github repoint https://hooks.example.com | censor
  webhook now targets https://hooks.example.com/ingress/github/$DIGEST
  $ wait_fake_server
  $ cat "$APPDIR/public-url"
  https://hooks.example.com

A repoint whose GitHub update fails leaves local truth ahead and says
re-run; re-running converges because the upsert is total.

  $ cat > repoint-fail.jsonl <<'EOF'
  > {"expect": {"request_line": "PATCH /app/hook/config HTTP/1.1"}, "http": {"status": 502, "json": {"message": "bad gateway"}}}
  > EOF
  $ start_fake_server repoint-fail.jsonl capture-repoint-fail gh-port
  $ BASE4="http://127.0.0.1:$(cat gh-port)"
  $ sed "s|\"api_base\":\"[^\"]*\"|\"api_base\":\"$BASE4\"|" "$APPDIR/app.json" > app.json.new
  $ mv app.json.new "$APPDIR/app.json" && chmod 600 "$APPDIR/app.json"
  $ mentatd github repoint https://h2.example.com 2>&1
  mentat: GitHub API responded 502: {"message":"bad gateway"}
  the public URL is recorded locally; GitHub still holds the old hook config — re-run `mentatd github repoint https://h2.example.com`
  [1]
  $ wait_fake_server
  $ cat "$APPDIR/public-url"
  https://h2.example.com

rotate-secret mints locally first, then upserts the config whole with the
fresh secret riding it.

  $ cp "$APPDIR/webhook-secret" secret.before
  $ cat > rotate.jsonl <<'EOF'
  > {"expect": {"request_line": "PATCH /app/hook/config HTTP/1.1", "body_contains": ["https://h2.example.com/ingress/github/feedfacefeedfacefeedfacefeedface"]}, "http": {"status": 200, "json": {}}}
  > EOF
  $ start_fake_server rotate.jsonl capture-rotate gh-port
  $ BASE5="http://127.0.0.1:$(cat gh-port)"
  $ sed "s|\"api_base\":\"[^\"]*\"|\"api_base\":\"$BASE5\"|" "$APPDIR/app.json" > app.json.new
  $ mv app.json.new "$APPDIR/app.json" && chmod 600 "$APPDIR/app.json"
  $ mentatd github rotate-secret
  rotated the App webhook secret; GitHub's hook now signs with it
  $ wait_fake_server
  $ cmp -s "$APPDIR/webhook-secret" secret.before && echo unchanged || echo rotated
  rotated
  $ grep -c "$(cat "$APPDIR/webhook-secret")" capture-rotate/request-1.json
  1

A PAT file wins the mode back — file presence, per routine, and every
surface says so.

  $ printf 'test-read-token\n' > config/mentat/routines/pr-review/secrets/read-token
  $ chmod 600 config/mentat/routines/pr-review/secrets/read-token
  $ mentatd routine list | censor
  NAME           DIGEST            STATE    AUTH  LAST
  pr-review      $DIGEST1  enabled  pat   -
  second-review  $DIGEST2  enabled  app   -
