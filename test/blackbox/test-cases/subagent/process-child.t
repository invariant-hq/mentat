Every subagent is a process: a plain `mentat run start` — no daemon running
anywhere — records the delegation and its own broker spawns the child as a
detached `mentat serve` process. The child settles its task in that process,
outlives the exited run client through the linger, and holds the session
fence under the serving label for its whole life — so a mid-linger
`mentat session send` that answers delivered can only have crossed the wire
into the child's own derived socket, where the live driver consumes it as
its next turn. The sessions work in a workspace subdirectory so the fixture
and capture files this test writes are not workspace file changes.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ export MENTAT_CHILD_LINGER=2

Provider fixtures are served content-matched (--unordered): the parent and
its eagerly-driven child reach the provider in nondeterministic order. The
fourth item answers the child's later mail turn.

  $ cat > stage.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > {"expect":{"body_contains":["mail for the child"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"MAIL_SEEN"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage.jsonl capture port

The run completes in one plain client process: the child settled in its own
process before the wait released the parent's final answer.

  $ mentat run start --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >run.out 2>run.err &
  $ RUN_PID=$!
  $ wait "$RUN_PID"
  $ mentat_cram subst 't-[0-9]{13}-[0-9a-f]{4}' 't-TURN' <run.out
  {"schema_version":1,"type":"run.started","session_id":"parent","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"parent"}
  {"schema_version":1,"type":"turn.started","session_id":"parent","turn_id":"t-TURN","mode":"build","origin":"user","model":"openai/responses:gpt-5.6-sol"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"SPA"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"WNE"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"D"}
  {"schema_version":1,"type":"turn.finished","session_id":"parent","outcome":"completed","text":"SPAWNED"}

No daemon exists: nothing on this path started one, and none wrote its
discovery file.

  $ [ ! -e "$XDG_DATA_HOME/mentat/daemon/daemon.json" ] && echo no-daemon
  no-daemon

The child is a live OS process distinct from the exited run client: its
fence owner records the serving label and a pid that is not the run's, and
the pid answers a signal probe while the server lingers.

  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture/request-*.json | head -n 1 | cut -d' ' -f2)
  $ LOCK="$XDG_DATA_HOME/mentat/sessions/$CHILD/run.lock"
  $ head -n 1 "$LOCK" | mentat_cram json .label
  serve-session
  $ CHILD_PID=$(head -n 1 "$LOCK" | mentat_cram json .pid)
  $ [ "$CHILD_PID" != "$RUN_PID" ] && echo distinct-process
  distinct-process
  $ kill -0 "$CHILD_PID" && echo child-alive
  child-alive

Mid-linger mail crosses the wire. The serving fence is held for the
server's whole life and the probes bracket the send, so a delivered answer
can only be the dial of the child's own socket — and the live driver
consumes the entry as its next turn against the still-scripted provider.

  $ mentat session send "$CHILD" "mail for the child" --cwd "$PWD/work" | mentat_cram subst 'sub-[0-9a-f]{16}' 'sub-CHILD'
  delivered sub-CHILD
  $ kill -0 "$CHILD_PID" && echo still-alive
  still-alive
  $ wait_fake_server

Settled idle with an empty queue, the child exits on its own after the
linger — no daemon to stop, nothing left running.

  $ tries=0; while kill -0 "$CHILD_PID" 2>/dev/null; do tries=$((tries + 1)); if [ "$tries" -gt 300 ]; then echo "child still up"; break; fi; sleep 0.1; done
  $ kill -0 "$CHILD_PID" 2>/dev/null || echo child-exited
  child-exited

The child journal holds both turns — the deterministic first task turn and
the consumed mail — driven entirely by the child's own process.

  $ mentat session show "$CHILD" --json --cwd "$PWD/work" | mentat_cram json .turns
  2
