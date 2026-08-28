A parent-agent death does not orphan a live delegation: the detached child
server survives the parent agent's SIGKILL, and the next activation of the
parent — a promptless resume — re-adopts it: recovery reconstructs the
parked wait from the durable claim, finds the child's fence held and its
endpoint answering, and observes rather than re-spawns, so the child's
eventual settlement integrates and the parent's wait completes. The
observer arm is proven by the fence's owner line: the same pid that started
the work finished it across the parent agent's death.

The child is held busy by a long shell tool while the parent agent dies.
The second fixture binds the first fixture's port: the child's provider
environment was frozen at its spawn, and the re-driven parent resolves the
same exported base URL. The sessions work in a workspace subdirectory, and
the tool's marker file is written outside it so the turns drain no
workspace notices.

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

Block until the parent's wait claim is durable — its call id appears in the
parent's persisted document — the exact state the agent's death must preserve
for its successor's recovery to reconstruct the park from.

  $ wait_parent_parked () {
  >   local doc="$XDG_DATA_HOME/mentat/sessions/parent/session.json" tries=0
  >   until grep -q wt-call "$doc" 2>/dev/null; do
  >     tries=$((tries + 1))
  >     if [ "$tries" -gt 100 ]; then echo "the wait claim never committed"; break; fi
  >     sleep 0.1
  >   done
  > }

Stage 1 — spawn, and hold the child busy on a long tool.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started && sleep 15\"}"}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat run start --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ wait_fake_server
  $ grep -c '"outcome":"completed"' stage1.out
  1
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ DELEG=$(grep -oh 'Spawned child [0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f3)
  $ wait_for_file child-started
  $ PID1=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)

Stage 2 — park the parent on the child, then kill the parent's agent. The
wait's tool claim is committed before the SIGKILL lands, the run client's
feed dies with the agent, and the child — its own session leader — keeps
working.

  $ cat > stage2.jsonl <<JSONL
  > {"expect":{"body_contains":["PLEASE_WAIT"],"body_not_contains":["wt-call"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"wt-item","call_id":"wt-call","name":"wait","arguments":"{\"children\":[\"$DELEG\"]}"}]}}
  > {"expect":{"body_contains":["ts-call"],"body_not_contains":["PLEASE_WAIT"]},"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["wt-call"]},"response":{"id":"r4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"PARENT_DONE"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage2.jsonl capture2 port2 --port "$(cat port1)"
  $ mentat run resume parent "PLEASE_WAIT" --json --cwd "$PWD/work" >stage2.out 2>stage2.err &
  $ RUN_PID=$!
  $ wait_parent_parked
  $ PARENT_PID=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/parent/run.lock" | mentat_cram json .pid)
  $ kill -9 "$PARENT_PID"
  $ wait "$RUN_PID" >/dev/null 2>&1 || true
  $ kill -0 "$PID1" && echo child-survived-the-parent-agent
  child-survived-the-parent-agent

Re-drive the parent with a promptless resume: it starts a fresh agent whose
recovery reconstructs the park, finds the held fence and the answering
endpoint, and observes; when the child's tool ends its settlement flows
through the observer into the recovered wait, the parent's turn completes,
and the run prints it and exits at settlement.

  $ mentat run resume parent --cwd "$PWD/work" 2>/dev/null
  PARENT_DONE
  $ wait_fake_server
  $ wait_child parent 2
  $ wait_child "$CHILD" 1
  $ wait_child_exit "$CHILD"
  $ wait_child_exit parent

The same pid finished the work that started it: the fence's owner line names
the original child server across the parent agent's death — the observer
arm, not a re-spawn.

  $ PID2=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)
  $ [ "$PID1" = "$PID2" ] && echo observed-not-respawned
  observed-not-respawned
  $ ls "$XDG_DATA_HOME/mentat/sessions/" | grep -cE '^sub-[0-9a-f]+$'
  1

The journals: the parent's second turn completed on the child's answer; the
child ran exactly one turn to completion, uninterrupted.

  $ mentat session export parent --format text --cwd "$PWD/work" >parent.transcript
  $ grep -c 'PARENT_DONE' parent.transcript
  1
  $ grep -c 'turn-finished' parent.transcript
  2
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" >child.transcript
  $ grep -c 'turn-finished' child.transcript
  1
  $ grep -c 'outcome=completed' child.transcript
  1
  $ grep -c 'CHILD_DONE' child.transcript
  1
