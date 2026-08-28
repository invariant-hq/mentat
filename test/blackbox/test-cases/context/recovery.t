Context is recomputed per turn, but the sealed tool catalog is not. Editing
AGENTS.md while a turn is parked changes the model-visible context (the prelude)
without changing the sealed tool declarations, so resuming the turn recovers its
execution against exactly one catalog family member — never a `recover_catalog`
fault — and the continuation request carries the freshly edited instructions.

  $ use_trusted_workspace
  $ cat > AGENTS.md <<'MD'
  > Original project instructions.
  > MD
  $ cat > ask.jsonl <<'JSONL'
  > {"expect":{"body_contains":["decide please","\"name\":\"ask_user\""]},"response":{"id":"rec-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"rec-item","call_id":"rec-call","name":"ask_user","arguments":"{\"prompt\":\"Which one?\"}"}]}}
  > JSONL
  $ start_fake_openai ask.jsonl capture-ask port-ask

A turn that asks a question parks, waiting for `run reply`.

  $ mentat run --json --cwd "$PWD" --id rec "decide please" >ask.out 2>/dev/null; echo exit:$?
  exit:3
  $ grep '"type":"session.waiting"' ask.out > waiting.out
  $ mentat_cram json .type waiting.out
  session.waiting
  $ decision=$(mentat_cram json .decision_id waiting.out)
  $ wait_fake_server

The workspace changes underneath the parked turn, and the parked agent dies
hard — the crash whose recovery this file pins. (A live parked agent would
simply continue in place; killing it forces the fresh-driver path.)

  $ AGENT_PID=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/rec/run.lock" | mentat_cram json .pid)
  $ kill -9 "$AGENT_PID"
  $ cat > AGENTS.md <<'MD'
  > Completely different project instructions.
  > MD
  $ cat > answer.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","rec-call","chosen"]},"response":{"id":"rec-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"recovered and continued"}]}]}}
  > JSONL
  $ start_fake_openai answer.jsonl capture-answer port-answer

The reply starts a fresh agent, whose recovery re-drives the active turn.
The sealed declarations still match one catalog, so recovery completes and
the turn finishes rather than faulting.

  $ mentat run reply rec --decision "$decision" --answer "chosen" --cwd "$PWD" 2>/dev/null
  recovered and continued
  $ wait_fake_server

The recovered continuation re-read the workspace: its request carries the edited
AGENTS.md, not the original.

  $ grep -o 'Completely different project instructions' capture-answer/request-1.json
  Completely different project instructions
  $ grep -q 'Original project instructions' capture-answer/request-1.json && echo present || echo absent
  absent
