The resident charter node over the wire: mentatd binds the webhook ingress
on loopback, a charter installed while the daemon runs answers to its
minted id at the next request, a signed pull_request delivery is answered
202 on the durable delivery receipt alone, and the pump then drives it
through the same pipeline the CLI fire takes — checkout, sealed run against
the fake provider, publication against the fake GitHub, egress receipted. A
verified ping is answered 202 and never receipted; a bad signature is a
content-free 401. The GitHub API base and the checkout remote reach the
node as flags on the daemon's own surface — the ambient
MENTAT_GITHUB_BASE_URL is poisoned to prove neither the node's reads nor
its publication children inherit it.

The repository fixture: a base branch, a feature head, and a bare remote
carrying refs/pull/7/head — laid out as <base>/acme/widgets.git, since the
--charter-git-base flag names a host prefix and the node derives each
charter's remote from the repository it watches.

  $ make_pr_fixture remotes/acme/widgets.git

The fakes come up before the daemon: the node's children run under the
environment the daemon captured at boot.

  $ cat > review.jsonl <<'JSONL'
  > {"expect":{"body_contains":[".mentat-review-","structured_output"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","usage":{"input_tokens":1000,"output_tokens":200},"output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"one finding\",\"findings\":[{\"severity\":\"P1\",\"path\":\"lib.txt\",\"line\":2,\"anchor\":\"new line\",\"title\":\"Appended line lacks purpose\",\"body\":\"The appended line introduces an unused entry.\"}]}"}]}}
  > JSONL
  $ start_fake_openai review.jsonl capture-run port-run
  $ RUN_PID=$MENTAT_FAKE_PROVIDER_PID
  $ cat > github.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$HEAD_SHA"}}}}
  > {"expect": {"request_line": "GET /user HTTP/1.1"}, "http": {"status": 200, "json": {"login": "owner"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/issues/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9001}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9002}}}
  > EOF
  $ start_fake_server github.jsonl capture-gh gh-port
  $ GH_URL="http://127.0.0.1:$(cat gh-port)"

The poison: were the node or any child it spawns to read the ambient base
URL, every GitHub round trip would refuse and no egress could land.

  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:9/"

The daemon starts with the ingress on an ephemeral loopback port — printed
to standard output — and the validated GitHub seams as flags. No charter is
installed yet.

  $ trap stop_daemon EXIT
  $ export MENTAT_DAEMON_MAX_IDLE=300
  $ mentatd --ingress-port 0 --github-base-url "$GH_URL" \
  >   --charter-git-base "$PWD/remotes" >daemon-serve.out 2>&1 &
  $ MENTAT_DAEMON_PID=$!
  $ wait_for_file "$XDG_DATA_HOME/mentat/daemon/daemon.json"
  $ IPORT=$(sed -n 's/^mentatd ingress: 127\.0\.0\.1://p' daemon-serve.out)
  $ BASE="http://127.0.0.1:$IPORT"

The charter is installed while the node runs — the file is the
registration, so the minted id resolves at the next request with no
restart.

  $ install_review_charter
  $ IID=$(cat "$CDIR/ingress.id")
  $ SECRET=$(cat "$CDIR/secrets/webhook")
  $ RECEIPTS="$PWD/state/mentat/charters/pr-review/receipts.jsonl"

A verified ping answers 202 — content-free — and leaves no receipt: the
receipt log speaks charter facts, and a foreign event kind is noted in the
trace log only.

  $ printf '{"zen":"keep it simple"}' > ping.json
  $ PSIG=$(mentat_cram hmac-sha256 "$SECRET" ping.json)
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: ping" \
  >   -H "X-Hub-Signature-256: sha256=$PSIG" --data-binary @ping.json \
  >   "$BASE/ingress/github/$IID"
  202
  $ test ! -e "$RECEIPTS" && echo no-receipt
  no-receipt
  $ grep -c 'ignoring ping delivery' daemon-serve.out
  1

The saved delivery names the fixture head; a wrong signature over the same
body is one content-free 401, counted in the trace log, and takes no
custody.

  $ cat > event.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 7, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$HEAD_SHA" },
  >     "base": { "ref": "main" } } }
  > EOF
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-Hub-Signature-256: sha256=deadbeef" --data-binary @event.json \
  >   "$BASE/ingress/github/$IID"
  401
  $ test ! -e "$RECEIPTS" && echo no-receipt
  no-receipt
  $ grep -c 'rejected delivery' daemon-serve.out
  1

The signed delivery: 202 the moment the delivery receipt is durable, then
the pump drives it to its disposition — the run against the fake provider,
the publication against the fake GitHub, the egress line.

  $ SIG=$(mentat_cram hmac-sha256 "$SECRET" event.json)
  $ curl -sS -w '%{http_code}\n' -H "X-GitHub-Event: pull_request" \
  >   -H "X-GitHub-Delivery: guid-1" -H "X-Hub-Signature-256: sha256=$SIG" \
  >   --data-binary @event.json "$BASE/ingress/github/$IID"
  202
  $ mentat_cram wait-line '"kind":"egress"' "$RECEIPTS"
  $ wait_fake_server
  $ wait "$RUN_PID"

The record carries the whole story, and the run child spoke to the fake
provider through the sealed review contract.

  $ grep -c '"kind":"delivery"' "$RECEIPTS"
  1
  $ grep -c '"disposition":"spawned"' "$RECEIPTS"
  1
  $ grep -c '"cause":"exited"' "$RECEIPTS"
  1
  $ grep -c '"summary":"created"' "$RECEIPTS"
  1
  $ grep -c '"name":"structured_output"' capture-run/request-1.json
  1
  $ grep -c 'charter pr-review: queued' daemon-serve.out
  1
  $ mentatd charter runs pr-review | censor --times
  $TS spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  $TS reaped github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2, exit 0, head settled, cause exited, $0.0110
