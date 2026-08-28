The fire pipeline end to end, with no live network: a saved pull_request
delivery is gated, receipted, run-claimed at spawn commitment, provisioned
as a hardened checkout from a local fixture remote, reviewed by a sealed run
against the fake provider, priced into the disposition receipt, rendered,
and published against a scripted GitHub API fake. Then the record does its
job: the same delivery reads dup off the run-claim alone, the sweep passes
over claimed heads, a policy edit re-admits the head under its new digest, a
claim torn between commitment and spawn is adopted by the next fire, and a
settled run whose publication failed is finished by the sweep's publisher
re-entry without a fresh run.

The repository fixture: a base branch, a feature head, and a bare remote
carrying refs/pull/7/head — what the derived https remote would serve, as a
local path the owner-named URL override points at.

  $ make_pr_fixture
  $ export MENTAT_CHARTER_GIT_URL="$PWD/origin.git"

The charter, installed, with both credentials in place.

  $ install_review_charter

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

  $ mentatd charter fire pr-review --event event.json | censor
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
  $ mentatd charter runs pr-review | censor --times
  $TS spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  $TS reaped github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2, exit 0, head settled, cause exited, $0.0110

The run carried the sealed contract and the trigger provenance: the
provider request carried the findings schema through the structured_output
tool, the reviewed tree in the run root is the fixture head itself, and the
run's journal — an ordinary session in the shared store — records the
charter's provenance and contract in its metadata, the trigger prompt as a
mailed queue entry, and the turn that consumed it as a triggered turn.

  $ grep -c '"name":"structured_output"' capture-run/request-1.json
  1
  $ RUN_ROOT=$(ls -d "$HOME"/.cache/mentat/charters/pr-review/runs/*)
  $ test "$(git -C "$RUN_ROOT" rev-parse HEAD)" = "$HEAD_SHA" && echo head-pinned
  head-pinned
  $ DOC="$XDG_DATA_HOME/mentat/sessions/$(basename "$RUN_ROOT")/session.json"
  $ grep -c '"triggered_from"' "$DOC"
  1
  $ grep -c '"run_policy"' "$DOC"
  1
  $ grep -c '"mode":"review"' "$DOC"
  1
  $ grep -c '"type":"trigger"' "$DOC"
  1
  $ grep -c '"type":"triggered"' "$DOC"
  1

Firing the identical delivery again is one receipt line reading dup: the
run-claim marker alone carries dup authority, so a redelivery is refused
without any network read — no head check is scripted, and none happens.

  $ mentatd charter fire pr-review --event event.json | censor
  dup github:acme/widgets#7@$DIGEST:head
  $ grep -c '"disposition":"dup"' "$RECEIPTS"
  1

The sweep passes over claimed heads silently: the open-PR listing names the
same head, its run-claim is held under the current policy digest and its
egress is decided, and nothing is synthesized — the canonical crontab line
dedupes exactly as the webhook path would.

  $ cat > listing.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 7, "draft": false, "author_association": "OWNER", "head": {"sha": "$HEAD_SHA"}, "base": {"ref": "main"}}]}}
  > EOF
  $ start_fake_server listing.jsonl capture-sweep gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentatd charter fire pr-review --sweep
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
  $ mentatd charter fire pr-review --sweep | censor
  spawned github:acme/widgets#7@$DIGEST1:head: session c-$DIGEST2
  reaped c-$DIGEST2: exit 0, head settled, $0.0110
  published: summary created, 1 threads
  $ wait_fake_server
  $ wait "$RUN2_PID"

A torn claim, produced honestly: a second pull request's delivery passes
the gate and the fence and commits its run-claim — then the checkout fails
against a broken remote, so the marker is held with no spawned line. The
receipt log stays intact.

  $ git -C work checkout -qb feature-8
  $ printf 'hello\nnew line\nanother\n' > work/lib.txt
  $ git -C work commit -qam change-8
  $ HEAD8=$(git -C work rev-parse HEAD)
  $ git -C origin.git fetch -q ../work feature-8
  $ git -C origin.git update-ref refs/pull/8/head "$HEAD8"
  $ cat > event8.json <<EOF
  > { "action": "opened",
  >   "repository": { "full_name": "acme/widgets" },
  >   "pull_request": { "number": 8, "draft": false,
  >     "author_association": "OWNER",
  >     "head": { "sha": "$HEAD8" },
  >     "base": { "ref": "main" } } }
  > EOF
  $ cat > github8.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/8 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$HEAD8"}}}}
  > EOF
  $ start_fake_server github8.jsonl capture-gh8 gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ export MENTAT_CHARTER_GIT_URL="$PWD/missing.git"
  $ mentatd charter fire pr-review --event event8.json 2>&1 | censor | sed -e 's/checkout: .*/checkout: (git error)/' -e 's/^mentat: git .*/mentat: (git error)/'
  refused github:acme/widgets#8@$DIGEST:head: checkout: (git error)
  mentat: (git error)
  [1]
  $ wait_fake_server
  $ grep '"disposition":"spawned"' "$RECEIPTS" | grep -c '#8@' || true
  0

The next fire adopts the torn claim and drives it to a real run — spawned,
not dup. This run's publication is cut short: the summary post is refused,
so the run settles with findings but no egress receipt.

  $ export MENTAT_CHARTER_GIT_URL="$PWD/origin.git"
  $ start_fake_openai review.jsonl capture-run3 port-run3
  $ RUN3_PID=$MENTAT_FAKE_PROVIDER_PID
  $ cat > github8b.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/8 HTTP/1.1"}, "http": {"status": 200, "json": {"head": {"sha": "$HEAD8"}}}}
  > {"expect": {"request_line": "GET /user HTTP/1.1"}, "http": {"status": 200, "json": {"login": "owner"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/8/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/issues/8/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/8/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9005}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/8/comments HTTP/1.1"}, "http": {"status": 502, "json": {"message": "bad gateway"}}}
  > EOF
  $ start_fake_server github8b.jsonl capture-gh8b gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentatd charter fire pr-review --event event8.json 2>&1 | censor
  spawned github:acme/widgets#8@$DIGEST1:head: session c-$DIGEST2
  reaped c-$DIGEST2: exit 0, head settled, $0.0110
  mentat: github publish exited 1 without upserting the summary
  [1]
  $ wait_fake_server
  $ wait "$RUN3_PID"
  $ grep '"disposition":"spawned"' "$RECEIPTS" | grep -c '#8@'
  1
  $ grep '"kind":"egress"' "$RECEIPTS" | grep -c '#8@' || true
  0

The sweep finishes what the failed publication left: the head ran to
settlement with findings and holds no egress receipt, so the sweep
re-enters the publisher only — no fresh run and no fresh spend (no provider
fake is even running), and the claimed head #7 stays silent beside it.

  $ cat > listing8.jsonl <<EOF
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls?state=open&per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": [{"number": 7, "draft": false, "author_association": "OWNER", "head": {"sha": "$HEAD_SHA"}, "base": {"ref": "main"}}, {"number": 8, "draft": false, "author_association": "OWNER", "head": {"sha": "$HEAD8"}, "base": {"ref": "main"}}]}}
  > {"expect": {"request_line": "GET /user HTTP/1.1"}, "http": {"status": 200, "json": {"login": "owner"}}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/pulls/8/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "GET /repos/acme/widgets/issues/8/comments?per_page=100 HTTP/1.1"}, "http": {"status": 200, "json": []}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/8/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9006}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/8/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9007}}}
  > EOF
  $ start_fake_server listing8.jsonl capture-gh8c gh-port
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat gh-port)"
  $ mentatd charter fire pr-review --sweep | censor
  published: summary created, 1 threads
  $ wait_fake_server
  $ grep '"kind":"egress"' "$RECEIPTS" | grep -c '#8@'
  1
  $ grep '"disposition":"spawned"' "$RECEIPTS" | grep -c '#8@'
  1
