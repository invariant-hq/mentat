# GitHub review

Mentat reviews a pull request in two halves. `mentat run review` runs the
headless review turn and produces a findings document — validated JSON, a
product contract like the rest of the [headless surface](headless.md).
`mentat github review` turns that document, the reviewed diff, and the
comments already on the pull request into ready-to-send GitHub API requests:
inline review threads for blocking findings, plus one sticky summary comment
that is updated in place across runs.

The second half is always dry. It reads its inputs, writes one JSON envelope
to stdout, and performs no network IO — posting is a short `gh api` loop that
you own. A ready-made GitHub Actions workflow wiring the whole pipeline ships
in this repository as `.github/workflows/mentat-review.yml`; this page shows
the underlying commands so you can wire your own CI, a cron job, or a local
script the same way.

## Producing the findings

Run the review from a checkout of the head you want reviewed, against the
base it will merge into:

```sh
mentat run review --base "$BASE_SHA" --json > run.jsonl
jq -c 'select(.type == "turn.finished") | .output // empty' \
  run.jsonl > findings.json
```

`run review` resolves the merge base itself, materializes the diff for the
model, and delivers the findings through a built-in schema, so the document
in `findings.json` is valid by construction. Without `--json` the document is
the entire stdout; with `--json` it rides the `turn.finished` event's
`output` member and the rest of the JSONL stream tells you *why* a run
produced nothing: `run.output_schema_failed`, `session.failed`, or a
`turn.finished` whose `outcome` is `step_limit` (all exit 1), an empty target
diff (exit 0 with a "nothing to review" line and no run started), or a park
on a decision (exit 3). Branch on the exit code before publishing anything.

## The reviewed diff

The publisher anchors findings by quoting exact source lines, so it must see
the same bytes the model reviewed. Compute the merge-base diff once, with the
same arguments the binary uses — quotePath and the diff prefixes are pinned
so local git configuration cannot change the path grammar the publisher
parses — and hand it to both halves of the pipeline:

```sh
git -c core.quotePath=false diff --no-color --no-ext-diff \
  --src-prefix=a/ --dst-prefix=b/ \
  "$(git merge-base "$BASE_SHA" "$HEAD_SHA")" "$HEAD_SHA" > review.diff
```

## What is already posted

Re-runs converge instead of stacking: a finding that already has a thread is
never reposted, and the summary comment is patched in place. That state lives
in the pull request itself, so fetch both comment families and keep only the
comments your posting identity wrote that carry a mentat marker — marker text
alone is forgeable by anyone who can comment, so the author filter is what
makes a comment yours:

```sh
{
  gh api --paginate "repos/$REPO/pulls/$NUMBER/comments" \
    --jq '.[] | {id: .id, body: .body, user: {login: .user.login}}'
  gh api --paginate "repos/$REPO/issues/$NUMBER/comments" \
    --jq '.[] | {id: .id, body: .body, user: {login: .user.login}}'
} | jq -s 'map(select(.user.login == "github-actions[bot]"
             and (.body | test("<!-- mentat-(review|finding:)"))))' \
  > posted.json
```

Substitute the login your token posts as; `github-actions[bot]` is the
identity of a GitHub Actions workflow token. The filter assumes no other
workflow posting under the same login reflects untrusted text into its
comments — a same-identity bot that echoes a PR author's words would carry a
forged marker past the author test.

## Rendering the requests

```sh
mentat github review --pr "$REPO#$NUMBER" --at "$HEAD_SHA" \
  --base-label "$BASE_REF" --diff review.diff --posted posted.json \
  < findings.json > out.json
```

`--at` is the full head commit SHA; it pins the permalinks and the thread
anchors to the tree that was actually reviewed. `--base-label` only names,
in the summary comment, what the head was reviewed against. `--origin`
stamps every marker the renderer emits with an origin token (default `ci`;
the shipped workflow passes `actions`), so comments from different
publishers stay distinguishable. Alongside the standard `schema_version`
and `type` envelope members, the envelope on stdout carries:

| Member | Meaning |
| --- | --- |
| `review` | Thread requests, one per blocking finding that anchors to the diff and is not already posted. |
| `summary` | The single summary request — a fresh POST, or a PATCH of the recorded summary comment. |
| `threads_safe` | `false` exactly when blocking findings exist but none produced a thread — none anchored to the diff and none is already posted: the signature of a diff that does not match the head. When it is `false`, no thread requests are emitted; the flag names why the list is empty. |

Each request is `{label, method, path, body}`: `label` is the finding's
fingerprint (or `null` on the summary), `method` and `path` name the GitHub
API call, and `body` is the complete request payload. Exit codes: 0 with the
envelope; 1 when the findings, diff, or posted listing does not decode; 2 for
a malformed flag.

## Posting

Finding text is model output reviewing attacker-influenceable code, so it
never touches a shell variable: extract each `body` with `jq` into a file and
hand the file to `gh api --input`. Methods and paths are renderer-generated
and safe to interpolate. Comment-delimiter sequences inside a finding body
are neutralized with an invisible zero-width space (U+200B), so code copied
out of a posted finding carries it.

The shipped workflow's "Post the review threads" and "Upsert the summary
comment" steps are the normative posting loop — one `gh api` call per
request, each body via `--input`; reproduce them rather than improvise.

The posting token needs `pull-requests: write` and nothing else; the review
half needs a model credential and no write scope at all. Keeping the two
halves in separate jobs (as the shipped workflow does) means untrusted code
is only ever checked out next to a read-only token, and the write token never
meets the model key.

Running the pipeline twice is safe by construction: threads already posted
are skipped, the summary converges to a PATCH, and a finding that vanished
from a later run leaves its thread alone rather than resolving it.
