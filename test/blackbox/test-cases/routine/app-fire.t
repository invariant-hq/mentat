The fire pipeline in App mode, end to end with no live network: the same
delivery fire.t drives under PAT files runs here with an owner-level
credential home and no token file anywhere — the fire mints a JWT over the
stored key, resolves the installation, mints a read-scoped installation
token for the head check, mints a write-scoped token only at publish time,
and takes its posting identity from the stored slug with no /user call.
Every mint is narrowed to the one repository and the one role.

The repository fixture and a routine with NO secrets at all.

  $ make_pr_fixture
  $ export MENTAT_ROUTINE_GIT_URL="$PWD/origin.git"
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
  $ printf 'Review the diff for defects.\n' > proposal/prompt.md
  $ printf '{"type":"object"}\n' > proposal/findings.schema.json
  $ mentatd routine add proposal >/dev/null

The GitHub fake, scripted in the App arm's exact request order: the
installation lookup and the read mint at connection build, the current-head
check under the minted read token, the write mint at publish entry, then
the posted listings — no /user: the posting identity is the stored slug —
and the two posts.

  $ cat > review.jsonl <<'JSONL'
  > {"expect":{"body_contains":[".mentat-review-","structured_output"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","usage":{"input_tokens":1000,"output_tokens":200},"output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"one finding\",\"findings\":[{\"severity\":\"P1\",\"path\":\"lib.txt\",\"line\":2,\"anchor\":\"new line\",\"title\":\"Appended line lacks purpose\",\"body\":\"The appended line introduces an unused entry.\"}]}"}]}}
  > JSONL
  $ start_fake_openai review.jsonl capture-run port-run
  $ RUN_PID=$MENTAT_FAKE_PROVIDER_PID
  $ cat > github.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/installation HTTP/1.1"}, "http": {"status": 200, "json": {"id": 987}}}
  > {"expect": {"request_line": "POST /app/installations/987/access_tokens HTTP/1.1", "body_contains": ["\"repositories\":[\"widgets\"]", "\"contents\":\"read\"", "\"pull_requests\":\"read\""]}, "http": {"status": 201, "json": {"token": "ghs_read_token"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$HEAD_SHA"}}}}
  > {"expect": {"request_line": "POST /app/installations/987/access_tokens HTTP/1.1", "body_contains": ["\"repositories\":[\"widgets\"]", "\"pull_requests\":\"write\""]}, "http": {"status": 201, "json": {"token": "ghs_write_token"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/issues/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9001}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9002}}}
  > EOF
  $ start_fake_server github.jsonl capture-gh gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"

The credential home, recording the fake's base — a fire configured for a
different base would refuse the App loudly.

  $ APPDIR="$XDG_CONFIG_HOME/mentat/github-app"
  $ mkdir -p "$APPDIR" && chmod 700 "$APPDIR"
  $ cat > "$APPDIR/app.json" <<EOF
  > {"github_app":1,"id":12345,"slug":"mentat-review-test","name":"mentat-review-test","client_id":"Iv1.test","html_url":"https://github.com/apps/mentat-review-test","api_base":"$MENTAT_GITHUB_BASE_URL","created_at":"2026-08-28T00:00:00Z"}
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

The saved delivery names the fixture head.

  $ cat > event.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 7, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$HEAD_SHA" },
  >     "base": { "ref": "main" } } }
  > EOF

The round trip: spawned, reaped settled with priced spend, published — on
minted tokens alone.

  $ mentatd routine fire pr-review --event event.json | censor
  spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  reaped c-$DIGEST2: exit 0, head settled, $0.0110
  published: summary created, 1 threads
  $ wait_fake_server
  $ wait "$RUN_PID"

The record carries the egress, and no request anywhere asked /user — the
posting identity came from the stored slug.

  $ RECEIPTS="$PWD/state/mentat/routines/pr-review/receipts.jsonl"
  $ grep -c '"kind":"egress"' "$RECEIPTS"
  1
  $ grep -rl "GET /user" capture-gh || echo no-user-call
  no-user-call

A fire configured for a different API base refuses the App loudly before
any mint, naming both hosts.

  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:1"
  $ mentatd routine fire pr-review --event event.json 2>&1 | censor
  mentat: github app: the App at $TESTCASE_ROOT/config/mentat/github-app was created against http://127.0.0.1:$PORT, but this fire is configured for http://127.0.0.1:1; re-run `mentatd github setup` against this host or write PAT files
  [1]
