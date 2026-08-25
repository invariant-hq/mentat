Untracked files in a headless review target: bare `git diff` never shows
them, so `run review` appends each to the materialized patch as a new-file
diff, and a worktree whose only change is a new file still reviews instead of
reporting an empty diff. This lives apart from review.t for its time budget.

The reviewed repository lives in its own subdirectory so the harness's
fixture files (provider script, captures, XDG homes) are not untracked
content of the reviewed worktree.

  $ mkdir repo
  $ cd repo
  $ git init -q
  $ git config user.email review@test.invalid
  $ git config user.name Reviewer
  $ use_trusted_workspace
  $ printf 'hello\n' > hello.txt
  $ git add hello.txt
  $ git commit -qm base

Before the fix, this worktree — clean but for the untracked fresh.txt — read
as an empty diff and no run began. Now the review runs; the model parks it on
a question (ask_user is in the review catalog), which keeps the patch file
for the resumed session — and lets the test read the synthesized hunk.

  $ printf 'fresh content\n' > fresh.txt
  $ cat > ../untracked.jsonl <<'JSONL'
  > {"expect":{"body_contains":[".mentat-review-","\"name\":\"ask_user\""]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"q-item","call_id":"q-call","name":"ask_user","arguments":"{\"prompt\":\"Is fresh.txt intentional?\"}"}]}}
  > JSONL
  $ start_fake_openai ../untracked.jsonl ../capture-untracked ../port-untracked
  $ mentat run review --uncommitted --cwd "$PWD" >../untracked.out 2>&1; echo exit:$?
  exit:3
  $ wait_fake_server

The kept patch renders fresh.txt as an added file — the same bytes the
publisher's diff parser anchors against.

  $ grep -c '^+++ b/fresh.txt$' .mentat-review-*.patch
  1
  $ grep -c '^+fresh content$' .mentat-review-*.patch
  1

The kept patch is mentat's own reserved scratch, never review content. With
fresh.txt resolved and removed, the worktree's only untracked file is the
leftover patch — and the next review sees an empty diff instead of reviewing
the previous review's diff as a new file. No provider is contacted on this
path.

  $ rm fresh.txt
  $ ls .mentat-review-*.patch | wc -l | tr -d ' '
  1
  $ mentat run review --uncommitted --cwd "$PWD"
  mentat: nothing to review; the diff for uncommitted is empty
