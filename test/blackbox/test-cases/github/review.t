Publishing a findings document as GitHub requests: `mentat github review` is
the always-dry publisher — findings on stdin, the reviewed diff and the
already-posted comments as files, one request envelope on stdout, and no
network anywhere.

  $ SHA=0123456789abcdef0123456789abcdef01234567

The reviewed diff, hand-written so the anchor lines are known bytes.

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
  > diff --git a/bin/main.ml b/bin/main.ml
  > index 2222222..3333333 100644
  > --- a/bin/main.ml
  > +++ b/bin/main.ml
  > @@ -10,2 +10,3 @@
  >  let main () =
  > +  let config = Sys.getenv "CONFIG" in
  >    run ()
  > DIFF

Four findings: two blocking ones whose anchors occur in the diff, one blocking
one whose anchor does not, and one non-blocking one (anchored, but severity
keeps it out of the threads).

  $ cat > findings.json <<'JSON'
  > {"summary": "Two blocking issues in the parse path.",
  >  "findings": [
  >    {"severity": "P0", "path": "lib/parse.ml", "line": 2,
  >     "anchor": "  let value = int_of_string text in",
  >     "title": "int_of_string raises on junk input",
  >     "body": "Any non-numeric text raises Failure and escapes parse."},
  >    {"severity": "P1", "path": "bin/main.ml", "line": 11,
  >     "anchor": "  let config = Sys.getenv \"CONFIG\" in",
  >     "title": "Sys.getenv raises when CONFIG is unset",
  >     "body": "Use Sys.getenv_opt and fail with a readable message."},
  >    {"severity": "P1", "path": "lib/other.ml", "line": 3,
  >     "anchor": "let helper = unused",
  >     "title": "Dead helper is still exported",
  >     "body": "Not part of this diff, so it cannot anchor."},
  >    {"severity": "P2", "path": "lib/parse.ml", "line": 4,
  >     "anchor": "  value + String.length trimmed",
  >     "title": "Result mixes value and length",
  >     "body": "The sum has no meaning; return the pair instead."}
  >  ]}
  > JSON

Fresh publish against an empty posted listing: the two anchored blocking
findings become thread requests labeled with their fingerprints, the other two
become summary rows, and the summary is a fresh POST with no summary id.

  $ echo '[]' > posted-empty.json
  $ mentat github review --pr acme/widgets#7 --at "$SHA" \
  >   --diff review.diff --posted posted-empty.json < findings.json > fresh.json
  $ mentat_cram json .type fresh.json
  github.review
  $ mentat_cram json '.review[].method' fresh.json
  POST
  POST
  $ mentat_cram json '.review[].path' fresh.json
  /repos/acme/widgets/pulls/7/comments
  /repos/acme/widgets/pulls/7/comments

Line-addressed thread requests pin the diff side explicitly — GitHub rejects
requests that omit it.

  $ mentat_cram json '.review[].body.side' fresh.json
  RIGHT
  RIGHT
  $ mentat_cram json .summary.method fresh.json
  POST
  $ mentat_cram json .summary.path fresh.json
  /repos/acme/widgets/issues/7/comments
  $ mentat_cram json .threads_safe fresh.json
  true

The emitted markers carry the origin token, default ci.

  $ mentat_cram json '.review[0].body.body' fresh.json | grep -c 'origin=ci -->'
  1
  $ mentat_cram json '.summary.body.body' fresh.json | grep -c 'mentat-review origin=ci -->'
  1

The thread labels are the findings' 16-hex fingerprints, extracted here so the
convergence fixture below stays self-maintaining rather than hardcoding hex.

  $ fp0=$(mentat_cram json '.review[0].label' fresh.json)
  $ fp1=$(mentat_cram json '.review[1].label' fresh.json)
  $ echo "$fp0" | grep -cE '^[0-9a-f]{16}$'
  1
  $ echo "$fp1" | grep -cE '^[0-9a-f]{16}$'
  1

Convergence: with the first fingerprint already posted under our marker and a
summary comment on record — both in the bare legacy grammar, which the scanner
must keep accepting — only the unposted finding earns a thread, and the
summary converges to a PATCH of the recorded comment.

  $ printf '[{"id": 101, "body": "noted <!-- mentat-finding:%s -->",
  >   "user": {"login": "github-actions[bot]"}},
  >  {"id": 4242, "body": "summary <!-- mentat-review -->",
  >   "user": {"login": "github-actions[bot]"}}]\n' "$fp0" > posted.json
  $ mentat github review --pr acme/widgets#7 --at "$SHA" --base-label main \
  >   --diff review.diff --posted posted.json < findings.json > converged.json
  $ [ "$(mentat_cram json '.review[].label' converged.json)" = "$fp1" ] \
  >   && echo only-the-unposted-thread
  only-the-unposted-thread
  $ mentat_cram json .summary.method converged.json
  PATCH
  $ mentat_cram json .summary.path converged.json
  /repos/acme/widgets/issues/comments/4242
  $ mentat_cram json '.summary.body.body' converged.json | grep -c 'against `main`'
  1
  $ mentat_cram json .threads_safe converged.json
  true

A diff that does not correspond to the findings anchors nothing: with blocking
findings present and not one finding anchored, threads_safe is false and no
thread request is emitted.

  $ cat > wrong.diff <<'DIFF'
  > diff --git a/README.md b/README.md
  > index 4444444..5555555 100644
  > --- a/README.md
  > +++ b/README.md
  > @@ -1,1 +1,2 @@
  >  # widgets
  > +A widget library.
  > DIFF
  $ mentat github review --pr acme/widgets#7 --at "$SHA" \
  >   --diff wrong.diff --posted posted-empty.json < findings.json > unsafe.json
  $ mentat_cram json .review unsafe.json
  []
  $ mentat_cram json .threads_safe unsafe.json
  false

A findings document that does not decode is exit 1 with the decode message on
stderr.

  $ echo '{"summary": 1}' | mentat github review --pr acme/widgets#7 \
  >   --at "$SHA" --diff review.diff --posted posted-empty.json
  mentat: summary: must be a string
  [1]

A diff that does not parse is exit 1.

  $ echo 'not a unified diff' > bad.diff
  $ mentat github review --pr acme/widgets#7 --at "$SHA" \
  >   --diff bad.diff --posted posted-empty.json < findings.json
  mentat: diff line 1: expected a diff file header
  [1]

A posted listing that does not decode is exit 1.

  $ echo '{"not": "an array"}' > bad-posted.json
  $ mentat github review --pr acme/widgets#7 --at "$SHA" \
  >   --diff review.diff --posted bad-posted.json < findings.json
  mentat: posted: must be a JSON array
  [1]

A malformed origin token is usage (exit 2).

  $ mentat github review --pr acme/widgets#7 --at "$SHA" --origin 'Actions!' \
  >   --diff review.diff --posted posted-empty.json < findings.json
  mentat: invalid --origin value Actions!: expected lowercase letters, digits, '-', or ':'
  [2]

A malformed pull-request coordinate or head SHA is usage (exit 2).

  $ mentat github review --pr acme-widgets-7 --at "$SHA" \
  >   --diff review.diff --posted posted-empty.json < findings.json
  mentat: invalid --pr value acme-widgets-7: expected OWNER/REPO#N
  [2]
  $ mentat github review --pr acme/widgets#7 --at deadbeef \
  >   --diff review.diff --posted posted-empty.json < findings.json
  mentat: invalid --at value deadbeef: expected a full lowercase commit SHA
  [2]
  $ mentat github review --at "$SHA" \
  >   --diff review.diff --posted posted-empty.json < findings.json
  mentat: --pr is required
  [2]
