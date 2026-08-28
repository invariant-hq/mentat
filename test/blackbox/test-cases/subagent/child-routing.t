Session-keyed child routing through the daemon: a delegated child whose
derived endpoint answers gets its session cone proxied to the live driver in
its own server, so a follow-up submitted against the child by id reaches the
child server instead of the root-keyed frozen view (whose attach could only
answer Busy against the fence that server holds). The fence's owner pid
proves the route: the same serve process that ran the task turn runs
the follow-up. A child killed mid-follow surfaces as a clean error on the
following client, never a hang, and the broker's respawn then completes the
interrupted turn.

The later fixtures bind the first fixture's port: a daemon-hosted instance
keeps the provider environment it booted with. The sessions work in a
workspace subdirectory, and the tool's marker files are written outside it so
the turns drain no workspace notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ trap stop_daemon EXIT
  $ export MENTAT_CHILD_LINGER=5

A durable allow rule lets the delegated child run its shell tool unattended.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

The child choreography helpers — wait_child, wait_child_exit, and the
$SOCK_BASE capture below — live in setup.sh beside the daemon helpers.

Stage 1 — spawn; the child settles its task turn and its server lingers.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ start_daemon
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat run start --attach --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ wait_fake_server
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ wait_child "$CHILD" 1
  $ PID1=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)

Stage 2 — a follow-up submitted against the child by id, through the daemon.
It reaches the live driver and streams the child's turn back to the caller.

  $ cat > stage2.jsonl <<'JSONL'
  > {"expect":{"body_contains":["SECOND_QUESTION"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SECOND_ANSWER"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage2.jsonl capture2 port2 --port "$(cat port1)"
  $ mentat run resume "$CHILD" "SECOND_QUESTION" --attach --json --cwd "$PWD/work" >stage2.out 2>stage2.err
  $ wait_fake_server
  $ mentat_cram subst 'sub-[0-9a-f]{16}' 'sub-CHILD' <stage2.out | mentat_cram subst 't-[0-9]{13}-[0-9a-f]{4}' 't-TURN'
  {"schema_version":1,"type":"run.started","session_id":"sub-CHILD","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"sub-CHILD"}
  {"schema_version":1,"type":"turn.started","session_id":"sub-CHILD","turn_id":"t-TURN","mode":"build","origin":"user","model":"openai/responses:gpt-5.6-sol"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"sub-CHILD","turn_id":"t-TURN","text":"SECON"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"sub-CHILD","turn_id":"t-TURN","text":"D_ANS"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"sub-CHILD","turn_id":"t-TURN","text":"WER"}
  {"schema_version":1,"type":"turn.finished","session_id":"sub-CHILD","outcome":"completed","text":"SECOND_ANSWER"}

The same serve process that ran the task turn ran the follow-up: the
fence's owner pid is unchanged, so the turn was driven in the child's own
server, not by an in-process attach in the daemon.

  $ PID2=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)
  $ [ "$PID1" = "$PID2" ] && echo routed-to-the-live-child
  routed-to-the-live-child

Stage 3 — a third turn holds the child mid-tool; killing the child's server
mid-follow ends the caller's stream with a clean error, and the broker's
respawned successor completes the turn.

  $ cat > stage3.jsonl <<'JSONL'
  > {"expect":{"body_contains":["THIRD_QUESTION"],"body_not_contains":["ts3-call"]},"response":{"id":"r4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts3-item","call_id":"ts3-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started3 && while [ ! -f ../go3 ]; do sleep 0.1; done && echo WAITED3\"}"}]}}
  > {"expect":{"body_contains":["ts3-call"]},"response":{"id":"r5","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"THIRD_DONE"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage3.jsonl capture3 port3 --port "$(cat port1)"
  $ mentat run resume "$CHILD" "THIRD_QUESTION" --attach --json --cwd "$PWD/work" >stage3.out 2>stage3.err &
  $ RUN3_PID=$!
  $ wait_for_file child-started3
  $ PID3=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock" | mentat_cram json .pid)
  $ kill -9 "$PID3"
  $ wait "$RUN3_PID"; echo "exit=$?"
  exit=1

The successor's recovery settles the killed tool claim Ambiguous and drives
the turn to completion; the interrupted follow surfaced as an error, never a
hang.

  $ touch go3
  $ wait_fake_server
  $ wait_child "$CHILD" 3
  $ wait_child_exit "$CHILD"
  $ stop_daemon
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" >child.transcript
  $ grep -c 'tool-settled(ambiguous' child.transcript
  1
  $ grep -c 'turn-finished' child.transcript
  3
  $ grep -c 'THIRD_DONE' child.transcript
  1
