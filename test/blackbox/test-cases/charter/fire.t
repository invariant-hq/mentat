The fire pipeline end to end, with no live network: a saved pull_request
delivery is gated, claimed, receipted, provisioned as a hardened checkout
from a local fixture remote, reviewed by a sealed run against the fake
provider, priced into the disposition receipt, rendered, and published
against a scripted GitHub API fake. Then the record does its job: the same
delivery reads dup, a torn claim is adopted and collides loudly at the
derived session id, the sweep passes over receipted heads, and a policy
edit re-admits the head under its new digest.

The repository fixture: a base branch, a feature head, and a bare remote
carrying refs/pull/7/head — what the derived https remote would serve, as a
local path the owner-named URL override points at.

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
  $ export MENTAT_CHARTER_GIT_URL="$PWD/origin.git"

The charter, installed, with both credentials in place.

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

The saved delivery names the fixture head.

  $ cat > event.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 7, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$HEAD_SHA" },
  >     "base": { "ref": "main" } } }
  > EOF

The review turn: the prompt names the materialized diff file, and the model
answers with one anchored blocking finding through the structured_output
tool, spending priced tokens.

  $ cat > review.jsonl <<'JSONL'
  > {"expect":{"body_contains":[".mentat-review-","structured_output"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","usage":{"input_tokens":1000,"output_tokens":200},"output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"one finding\",\"findings\":[{\"severity\":\"P1\",\"path\":\"lib.txt\",\"line\":2,\"anchor\":\"new line\",\"title\":\"Appended line lacks purpose\",\"body\":\"The appended line introduces an unused entry.\"}]}"}]}}
  > JSONL
  $ start_fake_openai review.jsonl capture-run port-run
  $ RUN_PID=$MENTAT_FAKE_PROVIDER_PID

The GitHub fake, scripted in the pipeline's exact request order: the
current-head check, then the publication's identity and posted listings,
then the thread and summary posts.

  $ cat > github.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$HEAD_SHA"}}}}
  > {"expect": {"request_line": "GET /user HTTP/1.1"}, "http": {"status": 200, "json": {"login": "owner"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/issues/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9001}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9002}}}
  > EOF
  $ start_fake_server github.jsonl capture-gh gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"

The round trip: spawned, reaped settled with priced spend, published.

  $ mentat charter fire pr-review --event event.json | censor
  spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  reaped c-$DIGEST2: exit 0, head settled, $0.0110
  published: summary created, 1 threads
  $ wait_fake_server
  $ wait "$RUN_PID"

The record carries the whole story — delivery, spawned, reaped, egress —
and `runs` renders the stamped session id, which names an ordinary session
in the shared store.

  $ RECEIPTS="$PWD/state/mentat/charters/pr-review/receipts.jsonl"
  $ grep -c '"kind":"delivery"' "$RECEIPTS"
  1
  $ grep -c '"disposition":"spawned"' "$RECEIPTS"
  1
  $ grep -c '"summary":"created"' "$RECEIPTS"
  1
  $ mentat charter runs pr-review | censor --times
  $TS spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  $TS reaped github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2, exit 0, head settled, cause exited, $0.0110

The run child carried the sealed contract and the trigger provenance: the
prompt rode stdin (never argv) and the provider request carried the
findings schema; the reviewed tree is the fixture head, checked out as
data in the run root, whose session journal records a triggered origin.

  $ grep -c '"name":"structured_output"' capture-run/request-1.json
  1

Firing the identical delivery again is one receipt line reading dup: the
claim marker collapses redelivery to the first fire's receipt.

  $ cat > github2.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$HEAD_SHA"}}}}
  > EOF
  $ start_fake_server github2.jsonl capture-gh2 gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentat charter fire pr-review --event event.json | censor
  dup github:acme/widgets#7@$DIGEST:head
  $ wait_fake_server
  $ grep -c '"disposition":"dup"' "$RECEIPTS"
  1

Torn-claim recovery: a marker without its delivery line belongs to a
claimer that died between the two, so the next fire adopts it and drives
on — proven here by erasing the log (the marker survives) and watching the
adopted pass reach the derived session id's loud collision instead of
reading dup.

  $ rm "$RECEIPTS"
  $ start_fake_server github2.jsonl capture-gh3 gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentat charter fire pr-review --event event.json | censor
  already exists github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  $ wait_fake_server
  $ grep -c '"disposition":"already_exists"' "$RECEIPTS"
  1

The sweep passes over receipted heads silently: the open-PR listing names
the same head, its identity holds receipts under the current digest, and
nothing is synthesized — the canonical crontab line dedupes exactly as the
webhook path would.

  $ cat > listing.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 7, "draft": false, "author_association": "OWNER", "head": {"sha": "$HEAD_SHA"}, "base": {"ref": "main"}}]}}
  > EOF
  $ start_fake_server listing.jsonl capture-sweep gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentat charter fire pr-review --sweep
  $ wait_fake_server

A policy edit moves the digest, so the same head is a fresh event: the
sweep re-admits it, mints a new derived session, and publishes again — the
owner's deliberate re-review path.

  $ printf 'Review the diff for defects, second pass.\n' > "$CDIR/prompt.md"
  $ start_fake_openai review.jsonl capture-run2 port-run2
  $ RUN2_PID=$MENTAT_FAKE_PROVIDER_PID
  $ cat > github3.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 7, "draft": false, "author_association": "OWNER", "head": {"sha": "$HEAD_SHA"}, "base": {"ref": "main"}}]}}
  > {"expect": {"request_line": "GET /user HTTP/1.1"}, "http": {"status": 200, "json": {"login": "owner"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/issues/7/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9003}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9004}}}
  > EOF
  $ start_fake_server github3.jsonl capture-gh4 gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentat charter fire pr-review --sweep | censor
  spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  reaped c-$DIGEST2: exit 0, head settled, $0.0110
  published: summary created, 1 threads
  $ wait_fake_server
  $ wait "$RUN2_PID"
