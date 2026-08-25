Headless review: `run review` resolves an explicit git diff target (--base,
--uncommitted, or --commit), materializes the diff to .mentat-review-diff.patch
at the workspace root for the turn, and drives a review-mode run whose findings
arrive through the built-in findings schema — validated JSON on stdout, or the
--json envelope's output member. The patch file never survives the run.

  $ git init -q
  $ git config user.email review@test.invalid
  $ git config user.name Reviewer
  $ use_trusted_workspace
  $ printf 'hello\n' > hello.txt
  $ git add hello.txt
  $ git commit -qm base
  $ git branch -m main

Exactly one target is required: none, or more than one, is a usage error
(exit 2) before any workspace or provider work.

  $ mentat run review --cwd "$PWD" 2>&1
  mentat: review requires a target: --base BRANCH, --uncommitted, or --commit SHA
  [2]
  $ mentat run review --base main --uncommitted --cwd "$PWD" 2>&1
  mentat: choose exactly one of --base, --uncommitted, or --commit
  [2]

A clean target diff is a no-op: a "nothing to review" line and exit 0, with no
run started. No provider is configured at this point, so a started run would
fail the credential gate (exit 1) rather than succeed — exit 0 proves no run
began.

  $ mentat run review --uncommitted --cwd "$PWD" 2>&1
  mentat: nothing to review; the diff for uncommitted is empty

A revision that names no commit is a usage error naming it.

  $ mentat run review --base no-such-branch --cwd "$PWD" 2>&1
  mentat: unknown base revision no-such-branch
  [2]

An uncommitted change reviews against HEAD: the diff reaches the patch file
(the prompt names it and the request carries the findings schema), the model's
conforming structured_output call lands verbatim on stdout, and the patch file
is removed with the run.

  $ printf 'new line\n' >> hello.txt
  $ cat > uncommitted.jsonl <<'JSONL'
  > {"expect":{"body_contains":[".mentat-review-diff.patch","\"name\":\"structured_output\"","anchor"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"one uncommitted finding\",\"findings\":[{\"severity\":\"P1\",\"path\":\"hello.txt\",\"line\":2,\"anchor\":\"new line\",\"title\":\"Appended line lacks purpose\",\"body\":\"The appended line introduces an unused entry.\"}]}"}]}}
  > JSONL
  $ start_fake_openai uncommitted.jsonl capture-unc port-unc
  $ mentat run review --uncommitted --cwd "$PWD" >unc.out 2>/dev/null
  $ wait_fake_server
  $ cat unc.out
  {"summary":"one uncommitted finding","findings":[{"severity":"P1","path":"hello.txt","line":2,"anchor":"new line","title":"Appended line lacks purpose","body":"The appended line introduces an unused entry."}]}
  $ test ! -e .mentat-review-diff.patch && echo patch-removed
  patch-removed

--base reviews the worktree against the merge base of the named branch and
HEAD; with --json the findings document rides turn.finished as the output
member.

  $ git checkout -qb feature
  $ git commit -qam change
  $ cat > base.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"branch review\",\"findings\":[]}"}]}}
  > JSONL
  $ start_fake_openai base.jsonl capture-base port-base
  $ mentat run review --json --base main --cwd "$PWD" >base.out 2>/dev/null
  $ wait_fake_server
  $ grep '"type":"turn.finished"' base.out | mentat_cram json .output.summary
  branch review
  $ test ! -e .mentat-review-diff.patch && echo patch-removed
  patch-removed

--commit reviews one commit alone, against its first parent.

  $ cat > commit.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"commit review\",\"findings\":[]}"}]}}
  > JSONL
  $ start_fake_openai commit.jsonl capture-commit port-commit
  $ mentat run review --commit HEAD --cwd "$PWD" >commit.out 2>/dev/null
  $ wait_fake_server
  $ mentat_cram json .summary commit.out
  commit review

A root commit has no parent to diff against; that is a usage-class refusal.

  $ root=$(git rev-list --max-parents=0 HEAD)
  $ mentat run review --commit "$root" --cwd "$PWD" 2>root.err
  [2]
  $ grep -c 'no parent to diff against' root.err
  1
