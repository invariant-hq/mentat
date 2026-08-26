A message to a RUNNING brokered child crosses the wire while the child still
runs — never parked until its exit. The child is held mid-turn by a long
shell tool; the parent then records a send_message and a follow_up. Both land
in the child journal as derived-id queue entries while the first turn is
still active (the follow-up's immediate turn is refused by the busy child and
parks as its queue-entry fallback, exactly as in-process delivery does), and
the journal's event order proves it: both queue facts precede the first
turn's settlement. Once the tool is released the child completes its task and
drains both entries as its own turns.

The second fixture binds the first fixture's port: a daemon-hosted instance
keeps the provider environment it booted with. The sessions work in a
workspace subdirectory, and the tool's marker files are written outside it so
the turns drain no workspace notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ trap stop_daemon EXIT
  $ export MENTAT_CHILD_LINGER=0.2

A durable allow rule lets the delegated child run its shell tool unattended.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

The child choreography helpers — wait_child, wait_child_exit, and the
$SOCK_BASE capture below — live in setup.sh beside the daemon helpers.

Stage 1 — spawn, and hold the child mid-turn on a gated shell tool.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started && while [ ! -f ../go ]; do sleep 0.1; done && echo WAITED\"}"}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ start_daemon
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat run start --attach --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ wait_fake_server
  $ grep -c '"outcome":"completed"' stage1.out
  1
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ DELEG=$(grep -oh 'Spawned child [0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f3)
  $ wait_for_file child-started

Stage 2 — deliver both message kinds while the child is mid-turn. The
fixture's last three entries are consumed only after the tool is released, so
the fake is not awaited until then.

  $ cat > stage2.jsonl <<JSONL
  > {"expect":{"body_contains":["PLEASE_MESSAGE"],"body_not_contains":["sm-call"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sm-item","call_id":"sm-call","name":"send_message","arguments":"{\"child\":\"$DELEG\",\"message\":\"extra context\"}"}]}}
  > {"expect":{"body_contains":["sm-call"],"body_not_contains":["fu-call"]},"response":{"id":"r4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"fu-item","call_id":"fu-call","name":"follow_up","arguments":"{\"child\":\"$DELEG\",\"message\":\"one more thing\"}"}]}}
  > {"expect":{"body_contains":["fu-call"]},"response":{"id":"r5","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"PARENT_DONE"}]}]}}
  > {"expect":{"body_contains":["WAITED"],"body_not_contains":["extra context"]},"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["extra context"],"body_not_contains":["PLEASE_MESSAGE"]},"response":{"id":"rc3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CTX_SEEN"}]}]}}
  > {"expect":{"body_contains":["one more thing"],"body_not_contains":["PLEASE_MESSAGE"]},"response":{"id":"rc4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"FU_DONE"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage2.jsonl capture2 port2 --port "$(cat port1)"
  $ mentat run resume parent "PLEASE_MESSAGE" --attach --json --cwd "$PWD/work" >stage2.out 2>stage2.err
  $ grep -c 'PARENT_DONE' stage2.out
  1

Both deliveries land in the child journal while the tool still holds its
first turn open: two derived-id queue facts, no settled turn yet.

  $ DOC="$XDG_DATA_HOME/mentat/sessions/$CHILD/session.json"
  $ tries=0; until [ "$(grep -o 'queue_updated' "$DOC" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ]; do
  >   tries=$((tries + 1))
  >   if [ "$tries" -gt 300 ]; then echo "the deliveries never landed"; break; fi
  >   sleep 0.1
  > done
  $ grep -o 'queue_updated' "$DOC" | wc -l | tr -d ' '
  2
  $ grep -c 'turn_finished' "$DOC"
  0
  [1]

Release the tool; the child completes its task turn and drains both entries
as its own turns.

  $ touch go
  $ wait_fake_server
  $ wait_child "$CHILD" 3
  $ wait_child_exit "$CHILD"
  $ stop_daemon
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" >child.transcript
  $ grep -c 'turn-finished' child.transcript
  3
  $ grep -c 'outcome=completed' child.transcript
  3
  $ grep -c 'CHILD_DONE' child.transcript
  1
  $ grep -c 'CTX_SEEN' child.transcript
  1
  $ grep -c 'FU_DONE' child.transcript
  1

The durable order pins the live delivery: both queue facts were recorded
before the first turn settled.

  $ first_settle=$(grep -n 'turn-finished' child.transcript | head -n 1 | cut -d: -f1)
  $ last_enqueue=$(grep -n 'queue-updated' child.transcript | tail -n 1 | cut -d: -f1)
  $ [ "$last_enqueue" -lt "$first_settle" ] && echo delivered-while-running
  delivered-while-running
