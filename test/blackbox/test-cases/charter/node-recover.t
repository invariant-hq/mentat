Recovery is observation, not redelivery: a run orphaned by a dead reaper is
settled honestly at the next node boot, and its interrupted publication is
finished by the sweep without a fresh run. The record is manufactured for
real — a CLI fire is SIGKILLed between its spawned receipt and its reap
while the run child lives on and settles alone — then a node boots over the
leftovers: the boot pass reads the freed run fence, writes the
reaped(recovered) disposition off the settled journal head, and the sweep
re-enters the publisher only. With an enabled webhook charter installed the
idle watchdog stands down — the charter is a standing commission, so the
node stays resident where a charterless daemon would stop itself.

The fixture: the fire.t repository, charter, and delivery.

  $ git init -q work
  $ git -C work config user.email t@test.invalid
  $ git -C work config user.name T
  $ printf 'hello\n' > work/lib.txt
  $ git -C work add lib.txt
  $ git -C work commit -qm base
  $ git -C work branch -m main
  $ git -C work checkout -qb feature
  $ printf 'hello\nnew line\n' > work/lib.txt
  $ git -C work commit -qam change
  $ HEAD_SHA=$(git -C work rev-parse HEAD)
  $ git clone -q --bare work origin.git
  $ git -C origin.git update-ref refs/pull/7/head "$HEAD_SHA"
  $ mkdir proposal
  $ cat > proposal/charter.json <<'EOF'
  > { "charter": 1, "name": "pr-review",
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
  $ mentat charter add proposal >/dev/null
  $ CDIR="$PWD/config/mentat/charters/pr-review"
  $ printf 'test-read-token\n' > "$CDIR/secrets/read-token"
  $ chmod 600 "$CDIR/secrets/read-token"
  $ printf 'test-write-token\n' > "$CDIR/secrets/write-token"
  $ chmod 600 "$CDIR/secrets/write-token"
  $ cat > event.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 7, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$HEAD_SHA" },
  >     "base": { "ref": "main" } } }
  > EOF

The doomed fire: the provider holds the response, so the fire process is
provably between its spawned receipt and its reap when SIGKILL lands. Its
run child keeps the provider connection and settles on its own.

  $ cat > review-held.jsonl <<'JSONL'
  > {"delay_ms":2000,"expect":{"body_contains":[".mentat-review-","structured_output"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","usage":{"input_tokens":1000,"output_tokens":200},"output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"one finding\",\"findings\":[{\"severity\":\"P1\",\"path\":\"lib.txt\",\"line\":2,\"anchor\":\"new line\",\"title\":\"Appended line lacks purpose\",\"body\":\"The appended line introduces an unused entry.\"}]}"}]}}
  > JSONL
  $ start_fake_openai review-held.jsonl capture-run port-run
  $ RUN_PID=$MENTAT_FAKE_PROVIDER_PID
  $ cat > github-head.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$HEAD_SHA"}}}}
  > EOF
  $ start_fake_server github-head.jsonl capture-gh gh-port
  $ GH1_PID=$MENTAT_FAKE_PROVIDER_PID
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ export MENTAT_CHARTER_GIT_URL="$PWD/origin.git"
  $ RECEIPTS="$PWD/state/mentat/charters/pr-review/receipts.jsonl"

The fire is spawned from a command substitution so the harness shell never
owns the job: a SIGKILLed job would otherwise leave an asynchronous death
notice on the harness's own stderr.

  $ FIRE_PID=$(mentat charter fire pr-review --event event.json >fire.out 2>&1 & echo $!)
  $ mentat_cram wait-line '"disposition":"spawned"' "$RECEIPTS"
  $ mentat_cram wait-file capture-run/request-1.json
  $ kill -9 "$FIRE_PID"
  $ wait "$GH1_PID"
  $ wait "$RUN_PID"

The child outlives its reaper: the spawned line has no reaped line, and the
freed run fence — acquired here the instant the dead child releases it — is
the proof no reaper survives. The probe helper is killed before the node
boots so the fence reads free.

  $ grep -c '"disposition":"reaped"' "$RECEIPTS" || true
  0
  $ SES=$(grep '"disposition":"spawned"' "$RECEIPTS" | tail -1 | mentat_cram json .session)
  $ mentat_cram lock "$XDG_DATA_HOME/mentat/sessions/$SES/run.lock" >lock.out 2>&1 &
  $ LOCK_HELPER=$!
  $ mentat_cram wait-line ready lock.out
  $ kill "$LOCK_HELPER" 2>/dev/null
  $ wait "$LOCK_HELPER" 2>/dev/null || true

The node boots over the record: the boot pass settles the orphan — reaped,
cause recovered, exit 0 off the settled head — then the sweep finds the
settled run with findings and no egress and re-enters the publisher; the
reconcile beat's own first pass re-reads the completed record and leaves it
alone. The ambient base URL is poisoned again: the flags are the node's
only configuration. MENTAT_DAEMON_MAX_IDLE is one second — the enabled
webhook charter pins residency, so the backstop never fires.

  $ cat > github-recover.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 7, "draft": false, "author_association": "OWNER", "head": {"sha": "$HEAD_SHA"}, "base": {"ref": "main"}}]}}
  > {"expect": {"request_line": "GET /user HTTP/1.1"}, "http": {"status": 200, "json": {"login": "owner"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/issues/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9001}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9002}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 7, "draft": false, "author_association": "OWNER", "head": {"sha": "$HEAD_SHA"}, "base": {"ref": "main"}}]}}
  > EOF
  $ start_fake_server github-recover.jsonl capture-gh2 gh-port2
  $ GH_URL="http://127.0.0.1:$(cat gh-port2)"
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:9/"
  $ unset MENTAT_CHARTER_GIT_URL
  $ trap stop_daemon EXIT
  $ export MENTAT_DAEMON_MAX_IDLE=1
  $ mentatd --github-base-url "$GH_URL" --charter-git-url "$PWD/origin.git" \
  >   >daemon-serve.out 2>&1 &
  $ MENTAT_DAEMON_PID=$!
  $ mentat_cram wait-line '"cause":"recovered"' "$RECEIPTS"
  $ mentat_cram wait-line '"kind":"egress"' "$RECEIPTS"
  $ wait_fake_server

One honest reap, one egress, and still the one spawned line: recovery
minted no run and spent nothing — no provider fake is even alive.

  $ grep -c '"cause":"recovered"' "$RECEIPTS"
  1
  $ grep -c '"kind":"egress"' "$RECEIPTS"
  1
  $ grep -c '"disposition":"spawned"' "$RECEIPTS"
  1
  $ grep -c '"summary":"created"' "$RECEIPTS"
  1
  $ mentat charter runs pr-review | censor --times
  $TS spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  $TS reaped github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2, exit 0, head settled, cause recovered, $0.0110

The residency rule, timed: after three seconds with zero connections and a
one-second idle budget, a charterless daemon would have stopped; the node
is still serving.

  $ sleep 3
  $ kill -0 "$MENTAT_DAEMON_PID" && echo resident
  resident
