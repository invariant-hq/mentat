A brokered child SIGKILLed mid-turn is re-materialized and still settles the
parent's wait: the broker's reaper observes the exit, finds the child journal
unsettled (an open tool claim — the kill landed mid-operation), and spawns a
successor whose recovery settles the claim Ambiguous and drives the turn to
completion; the observer folds that settlement into the parent, whose parked
wait completes instead of parking forever. The re-materialization is proven by
the fence's owner line: a different pid finished the work than started it.

The child is held mid-turn by a long shell tool, not by a held provider
response, so every fixture response is written to a live connection. The
second fixture binds the first fixture's port: a daemon-hosted instance keeps
the provider environment it booted with, so the respawned child and the
resumed parent both call the original base URL. The sessions work in a
workspace subdirectory, and the tool's marker file is written outside it so
the turns drain no workspace notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ trap stop_daemon EXIT
  $ export MENTAT_CHILD_LINGER=0.2

A durable allow rule lets the delegated child run its shell tool unattended —
the child's own composition resolves the same user config the parent's does.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

The child choreography helpers — wait_child, wait_child_exit, and the
$SOCK_BASE capture below — live in setup.sh beside the daemon helpers.

Stage 1 — spawn, and hold the child mid-turn. The child's task turn starts a
long shell tool; its marker file is the rendezvous proving the tool claim is
open when the kill lands.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started && sleep 15\"}"}]}}
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
  $ PID1=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)

Stage 2 — the crash. The continuation fixture goes up on the same port first,
so the successor's recovery has a provider to finish against; then the child
is SIGKILLed mid-tool and the parent made to wait on it. The wait parks until
the successor settles; nothing else can complete it.

  $ cat > stage2.jsonl <<JSONL
  > {"expect":{"body_contains":["PLEASE_WAIT"],"body_not_contains":["wt-call"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"wt-item","call_id":"wt-call","name":"wait","arguments":"{\"children\":[\"$DELEG\"]}"}]}}
  > {"expect":{"body_contains":["ts-call"],"body_not_contains":["PLEASE_WAIT"]},"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["wt-call"]},"response":{"id":"r4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"PARENT_DONE"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage2.jsonl capture2 port2 --port "$(cat port1)"
  $ kill -9 "$PID1"
  $ mentat run resume parent "PLEASE_WAIT" --attach --json --cwd "$PWD/work" >stage2.out 2>stage2.err
  $ wait_fake_server
  $ grep -c '"outcome":"completed"' stage2.out
  1
  $ grep -c 'PARENT_DONE' stage2.out
  1

The wait's answer carried the successor's result, and the child settled to a
completed turn under a different pid than the one the kill removed — the
broker respawned it rather than abandoning the delegation.

  $ wait_child "$CHILD" 1
  $ wait_child_exit "$CHILD"
  $ PID2=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)
  $ [ "$PID1" != "$PID2" ] && echo re-materialized-under-a-new-pid
  re-materialized-under-a-new-pid
  $ ls "$XDG_DATA_HOME/mentat/sessions/" | grep -cE '^sub-[0-9a-f]+$'
  1

The child journal tells the whole story durably: the killed tool claim
settled Ambiguous (the kill outran the outcome, and the orphaned tool tree
may still be running — recovery does not pretend otherwise), and the turn
then completed with the successor's answer.

  $ stop_daemon
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" >child.transcript
  $ grep -c 'tool-settled(ambiguous' child.transcript
  1
  $ grep -c 'turn-finished' child.transcript
  1
  $ grep -c 'outcome=completed' child.transcript
  1
  $ grep -c 'CHILD_DONE' child.transcript
  1
