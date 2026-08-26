Sending a review envelope to the GitHub API: `mentat github publish` reads the
envelope `github review` prints and issues its requests — threads in envelope
order, then the summary — printing one JSON outcome line per request. The API
base is overridden onto a local fake, and the token comes from the
environment, never from the command line.

  $ unset GITHUB_TOKEN MENTAT_GITHUB_BASE_URL
  $ SHA=0123456789abcdef0123456789abcdef01234567

The reviewed diff and findings, hand-written so the envelope carries two
thread requests and one summary request (see review.t for the anchoring
rules).

  $ cat > review.diff <<'DIFF'
  > diff --git a/lib/parse.ml b/lib/parse.ml
  > index 0000000..1111111 100644
  > --- a/lib/parse.ml
  > +++ b/lib/parse.ml
  > @@ -1,3 +1,4 @@
  >  let parse text =
  > +  let value = int_of_string text in
  >    let trimmed = String.trim text in
  > -  ignore trimmed
  > +  value + String.length trimmed
  > DIFF
  $ cat > findings.json <<'JSON'
  > {"summary": "Two blocking issues in the parse path.",
  >  "findings": [
  >    {"severity": "P0", "path": "lib/parse.ml", "line": 2,
  >     "anchor": "  let value = int_of_string text in",
  >     "title": "int_of_string raises on junk input",
  >     "body": "Any non-numeric text raises Failure and escapes parse."},
  >    {"severity": "P1", "path": "lib/parse.ml", "line": 4,
  >     "anchor": "  value + String.length trimmed",
  >     "title": "Result mixes value and length",
  >     "body": "The sum has no meaning; return the pair instead."}
  >  ]}
  > JSON
  $ echo '[]' > posted.json
  $ mentat github review --pr acme/widgets#7 --at "$SHA" \
  >   --diff review.diff --posted posted.json < findings.json > envelope.json
  $ fp0=$(mentat_cram json '.review[0].label' envelope.json)
  $ fp1=$(mentat_cram json '.review[1].label' envelope.json)

Without a token the publisher refuses before reading anything.

  $ mentat github publish --pr acme/widgets#7 < envelope.json
  mentat: GITHUB_TOKEN is not set; the publisher takes its token from the environment, never from the command line
  [1]

The happy path: the fake answers 201 three times; the publisher sends the two
threads in envelope order, then the summary, and exits 0.

  $ export GITHUB_TOKEN=test-token
  $ cat > publish-ok.jsonl <<'SCRIPT'
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9001}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/pulls/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9002}}}
  > {"expect": {"request_line": "POST /repos/acme/widgets/issues/7/comments HTTP/1.1"}, "http": {"status": 201, "json": {"id": 9003}}}
  > SCRIPT
  $ start_fake_server publish-ok.jsonl capture-ok
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat server-port)"
  $ mentat github publish --pr acme/widgets#7 < envelope.json > outcome.jsonl
  $ wait_fake_server
  $ grep -c '"type":"github.publish"' outcome.jsonl
  3
  $ grep -c '"status":201' outcome.jsonl
  3
  $ sed -n 1p outcome.jsonl | grep -c "\"label\":\"$fp0\""
  1
  $ sed -n 2p outcome.jsonl | grep -c "\"label\":\"$fp1\""
  1
  $ sed -n 3p outcome.jsonl | grep -c '"label":null'
  1

The requests carried the token as a bearer authorization and the first thread
body was the first envelope thread.

  $ grep -c '^authorization: Bearer test-token' capture-ok/request-1.headers
  1
  $ grep -c "$fp0" capture-ok/request-1.json
  1
  $ grep -c "$fp1" capture-ok/request-2.json
  1

Fault isolation: a non-2xx answer is recorded on its line — status and an
error excerpt — and the run continues to the remaining requests; the exit
code turns 1.

  $ cat > publish-fail.jsonl <<'SCRIPT'
  > {"http": {"status": 422, "json": {"message": "Validation Failed"}}}
  > {"http": {"status": 201, "json": {"id": 9002}}}
  > {"http": {"status": 201, "json": {"id": 9003}}}
  > SCRIPT
  $ start_fake_server publish-fail.jsonl capture-fail
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat server-port)"
  $ mentat github publish --pr acme/widgets#7 < envelope.json > outcome.jsonl
  [1]
  $ wait_fake_server
  $ grep -c '"type":"github.publish"' outcome.jsonl
  3
  $ sed -n 1p outcome.jsonl | grep -c '"status":422'
  1
  $ sed -n 1p outcome.jsonl | grep -c '"error":.*Validation Failed'
  1
  $ grep -c '"status":201' outcome.jsonl
  2

An envelope with threads_safe false publishes only the summary — here the
converged PATCH of a recorded summary comment.

  $ cat > unsafe.json <<JSON
  > {"type": "github.review",
  >  "review": [{"label": "$fp0", "method": "POST",
  >              "path": "/repos/acme/widgets/pulls/7/comments",
  >              "body": {"body": "never sent"}}],
  >  "summary": {"label": null, "method": "PATCH",
  >              "path": "/repos/acme/widgets/issues/comments/4242",
  >              "body": {"body": "summary"}},
  >  "threads_safe": false}
  > JSON
  $ cat > publish-safe.jsonl <<'SCRIPT'
  > {"expect": {"request_line": "PATCH /repos/acme/widgets/issues/comments/4242 HTTP/1.1"}, "http": {"status": 200, "json": {"id": 4242}}}
  > SCRIPT
  $ start_fake_server publish-safe.jsonl capture-safe
  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:$(cat server-port)"
  $ mentat github publish --pr acme/widgets#7 < unsafe.json
  {"schema_version":1,"type":"github.publish","label":null,"status":200}
  $ wait_fake_server

An envelope whose requests target another repository is refused before any
request is sent — no server is listening here, and none is needed.

  $ mentat github publish --pr other/repo#7 < unsafe.json
  mentat: request summary targets /repos/acme/widgets/issues/comments/4242, outside other/repo#7
  [1]

A tampered envelope cannot point the token outside the repository: a
dot-segment path is refused at decode (GitHub's edge would normalize it past
the prefix check), and a control-byte label is flattened to printable ASCII
before it reaches the terminal. Neither needs a server.

  $ cat > traversal.json <<'JSON'
  > {"type": "github.review", "review": [],
  >  "summary": {"label": "bad\u001b[2Jlabel", "method": "POST",
  >              "path": "/repos/acme/widgets/../../orgs/evil/x",
  >              "body": {"body": "s"}},
  >  "threads_safe": true}
  > JSON
  $ mentat github publish --pr acme/widgets#7 < traversal.json
  mentat: envelope.summary.path: must not contain empty, ".", or ".." segments
  [1]
  $ cat > hostile-label.json <<'JSON'
  > {"type": "github.review", "review": [],
  >  "summary": {"label": "bad\u001b[2Jlabel", "method": "POST",
  >              "path": "/repos/acme/widgets/issues/7/comments",
  >              "body": {"body": "s"}},
  >  "threads_safe": true}
  > JSON
  $ mentat github publish --pr other/repo#7 < hostile-label.json
  mentat: request bad [2Jlabel targets /repos/acme/widgets/issues/7/comments, outside other/repo#7
  [1]

A transport failure aborts with the offending request named; nothing listens
on the dead port.

  $ export MENTAT_GITHUB_BASE_URL="http://127.0.0.1:1"
  $ mentat github publish --pr acme/widgets#7 < unsafe.json 2>&1 | grep -c '^mentat: publish summary:'
  1
  [1]

Bytes that are not a review envelope are refused whole.

  $ echo 'not json' | mentat github publish --pr acme/widgets#7
  mentat: envelope: Expected u while parsing null but found: o
  File "-", line 1, characters 0-2:
  [1]
