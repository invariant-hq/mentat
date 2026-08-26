`run review --attach` drives the review turn on the daemon's engine. The step
cap rides the prompt command over the wire, so the daemon honors --max-steps
rather than its own configured default. The model flags have no wire carrier —
the daemon composes its turn options from its own configuration — so combined
with --attach they refuse as usage errors before any daemon work.

  $ git init -q
  $ git config user.email review@test.invalid
  $ git config user.name Reviewer
  $ use_trusted_workspace
  $ printf 'hello\n' > hello.txt
  $ git add hello.txt
  $ git commit -qm base
  $ printf 'new line\n' >> hello.txt

The refusals fire at flag validation: no daemon spawned, no provider needed.

  $ mentat run review --uncommitted --attach --model gpt-5.6-sol --cwd "$PWD" 2>&1
  mentat: --model cannot be combined with --attach (the daemon resolves the model from its own configuration)
  [2]
  $ mentat run review --uncommitted --attach --reasoning high --cwd "$PWD" 2>&1
  mentat: --reasoning cannot be combined with --attach (the daemon resolves reasoning effort from its own configuration)
  [2]

A one-step cap through the daemon: the fake's first response is prose, not a
structured_output call, so a turn free to continue would request again — the
capped review turn instead settles at its step limit after that single step.
The engine then owes one wind-down turn; line 2 answers it, and its expect
guard pins that the second request is the wind-down, not a continuation of
the capped turn.

  $ trap stop_daemon EXIT
  $ cat > attach.jsonl <<'JSONL'
  > {"expect":{"body_contains":[".mentat-review-"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"still reviewing"}]}]}}
  > {"expect":{"body_contains":["reached its step limit"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"wrapped up"}]}]}}
  > JSONL
  $ start_fake_openai attach.jsonl
  $ start_daemon
  $ mentat run review --uncommitted --attach --max-steps 1 --json --cwd "$PWD" >att.out 2>/dev/null; echo exit:$?
  exit:1
  $ wait_fake_server
  $ grep '"type":"turn.finished"' att.out | mentat_cram json .outcome
  step_limit
