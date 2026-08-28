A cancelled child that had to be killed does not resume the cancelled work:
the child is frozen (SIGSTOP) so it can hear neither the semantic interrupt
nor SIGTERM, the parent's interrupt — forwarded by the run client over the
parent agent's socket — cascades the cancel, and the parent agent broker's
escalation ends in SIGKILL. The respawned successor boots with the interrupt
intent carried (--interrupted), so its journal ends in one terminal
interrupted fact — the killed tool claim settled Ambiguous, and the resumed
turn was cut down before completing — never in the cancelled work's answer.

The second fixture binds the first fixture's port and holds its one
continuation response behind a long delay: if the successor's recovery gets a
provider request off before the interrupt lands, that request is cancelled
mid-flight rather than answered. The sessions work in a workspace
subdirectory, and the tool's marker file is written outside it so the turns
drain no workspace notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)

A durable allow rule lets the delegated child run its shell tool unattended.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

The agent choreography helpers — wait_child, wait_child_exit, and the
$SOCK_BASE capture below — live in setup.sh.

Stage 1 — spawn, and hold the child mid-turn on a gated shell tool.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started && while [ ! -f ../go ]; do sleep 0.1; done && echo WAITED\"}"}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat run start --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ wait_fake_server
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ DELEG=$(grep -oh 'Spawned child [0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f3)
  $ wait_for_file child-started
  $ PID1=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)

Stage 2 — freeze the child, park the parent on the wait, then interrupt the
parent. The cascade cancels the child; the frozen process cannot hear the
semantic interrupt or SIGTERM, so the escalation ends in SIGKILL, and the
parent's interrupted turn settles without waiting for it.

  $ cat > stage2.jsonl <<JSONL
  > {"expect":{"body_contains":["PLEASE_WAIT"],"body_not_contains":["wt-call"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"wt-item","call_id":"wt-call","name":"wait","arguments":"{\"children\":[\"$DELEG\"]}"}]}}
  > {"expect":{"body_contains":["ts-call"]},"delay_ms":60000,"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"RESUMED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage2.jsonl capture2 port2 --port "$(cat port1)"
  $ kill -STOP "$PID1"
  $ mentat run resume parent "PLEASE_WAIT" --json --cwd "$PWD/work" >stage2.out 2>stage2.err &
  $ RUN_PID=$!
  $ PARENT_DOC="$XDG_DATA_HOME/mentat/sessions/parent/session.json"
  $ tries=0; until grep -q wt-call "$PARENT_DOC" 2>/dev/null; do
  >   tries=$((tries + 1))
  >   if [ "$tries" -gt 100 ]; then echo "the wait claim never committed"; break; fi
  >   sleep 0.1
  > done
  $ kill -INT "$RUN_PID"
  $ wait "$RUN_PID"; echo "exit=$?"
  exit=130

The broker's escalation kills the frozen child and respawns it with the
interrupt intent; the successor's journal ends in one terminal interrupted
fact under a new pid, and the cancelled work never completes.

  $ wait_child "$CHILD" 1
  $ PID2=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)
  $ [ "$PID1" != "$PID2" ] && echo re-materialized-under-a-new-pid
  re-materialized-under-a-new-pid
  $ wait_child_exit "$CHILD"
  $ touch go
  $ kill "$MENTAT_FAKE_PROVIDER_PID" 2>/dev/null
  $ wait "$MENTAT_FAKE_PROVIDER_PID" 2>/dev/null
  [143]
  $ wait_child_exit parent
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" >child.transcript
  $ grep -c 'tool-settled(ambiguous' child.transcript
  1
  $ grep -c 'turn-finished' child.transcript
  1
  $ grep -c 'outcome=interrupted' child.transcript
  1
  $ grep -c 'RESUMED' child.transcript
  0
  [1]
