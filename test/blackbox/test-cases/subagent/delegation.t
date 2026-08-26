The delegation journey, blackbox through the binary: spawn -> wait ->
send_message -> follow_up, against the daemon's brokered child backend — the
child runs as a detached per-session server the daemon's broker spawns, and
its settlement integrates into the parent through the broker's observation.
The two content-derived identities — the parent-minted child session id and
the child's deterministic first-turn id — are extracted verbatim and proven
stable across a lost-journal re-drive: deleting the child's journal and
re-attaching the parent re-materializes the same child under the same ids,
and the child's normalized transcript is byte-identical across the two
materializations. These goldens predate the brokered backend, so any drift
between backends breaks this file.

Provider fixtures are served content-matched (--unordered): a parent and its
eagerly-driven child reach the provider in nondeterministic order. The engine
runs inside the daemon so a delegated child keeps driving after each run
client exits; every stage waits for the child's durable settlement before
stopping the daemon, and exports also wait for the detached child server to
exit (its endpoint directory is the visible sign), because export and the
lingering child contend for the session fence. The linger is shortened so
those exits do not pace the test. The sessions work in a workspace
subdirectory so the fixture and capture files this test writes are not
workspace file changes the turns would drain as notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ trap stop_daemon EXIT
  $ export MENTAT_CHILD_LINGER=0.2

Poll a session's fence-free view until it is idle with the expected number of
settled turns.

  $ wait_child () {
  >   local child="$1" want="$2" tries=0 out phase turns
  >   while :; do
  >     out=$(mentat session show "$child" --json --cwd "$PWD/work" 2>/dev/null) || out=
  >     phase=$(printf '%s' "$out" | mentat_cram json .phase 2>/dev/null) || phase=
  >     turns=$(printf '%s' "$out" | mentat_cram json .turns 2>/dev/null) || turns=
  >     if [ "$phase" = idle ] && [ "$turns" = "$want" ]; then break; fi
  >     tries=$((tries + 1))
  >     if [ "$tries" -gt 300 ]; then echo "wait_child timed out: $out"; break; fi
  >     sleep 0.1
  >   done
  > }

Block until a child's detached server has exited — its endpoint directory
under the daemon's socket tree is gone — so a following export finds the
session fence free. $SOCK_BASE is captured from discovery once the first
daemon is up.

  $ wait_child_exit () {
  >   local dir="$SOCK_BASE/$1" tries=0
  >   while [ -e "$dir" ]; do
  >     tries=$((tries + 1))
  >     if [ "$tries" -gt 300 ]; then echo "child server still up: $dir"; break; fi
  >     sleep 0.1
  >   done
  > }

Stage 1 — spawn. The parent's turn records the delegation edge; the receipt
names both derived identities; the child completes its task turn in its own
detached server after the run client has exited.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ start_daemon
  $ SOCK_BASE="$(dirname "$(mentat_cram json .socket "$XDG_DATA_HOME/mentat/daemon/daemon.json")")/s"
  $ mentat run start --attach --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ wait_fake_server

The parent's lifecycle stream: the delegation rides the journal, not the run
events, so the stream is the plain turn envelope.

  $ mentat_cram subst 't-[0-9]{13}-[0-9a-f]{4}' 't-TURN' <stage1.out
  {"schema_version":1,"type":"run.started","session_id":"parent","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"parent"}
  {"schema_version":1,"type":"turn.started","session_id":"parent","turn_id":"t-TURN","mode":"build","origin":"user","model":"openai/responses:gpt-5.6-sol"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"SPA"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"WNE"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"D"}
  {"schema_version":1,"type":"turn.finished","session_id":"parent","outcome":"completed","text":"SPAWNED"}

The spawn receipt advertised both derived identities: the delegation id the
model addresses the child by, and the child session id.

  $ DELEG=$(grep -oh 'Spawned child [0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f3)
  $ echo "$DELEG" | grep -cE '^[0-9a-f]{64}$'
  1
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ echo "$CHILD" | grep -cE '^sub-[0-9a-f]{16}$'
  1

Wait for the child to settle inside the daemon, then stop it and read the
journals. The durable edge in the parent journal names the same child
session, and the child's first-turn id is the deterministic mint off the
delegation id — 20 hex characters, no clock and no sequence.

  $ wait_child "$CHILD" 1
  $ wait_child_exit "$CHILD"
  $ stop_daemon
  $ mentat session export parent --format json --cwd "$PWD/work" >parent1.ndjson
  $ grep -c "\"child\":\"$CHILD\"" parent1.ndjson
  1
  $ mentat session export "$CHILD" --format json --cwd "$PWD/work" >child1.ndjson
  $ T1=$(sed -n '2p' child1.ndjson | mentat_cram json '.document.events[0].turn.id')
  $ echo "$T1" | grep -cE '^[0-9a-f]{20}$'
  1
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" | censor >child1.transcript
  $ cat child1.transcript
  session sub-$DIGEST1
  phase: idle
  lifecycle: active
  cwd: $TESTCASE_ROOT/work
  events: 4
  1. turn-started({ id = $DIGEST2; origin = user; input = user[1 content block(s)]; model = openai/responses:gpt-5.6-sol })
  2. provider-requested({ id = $DIGEST3; turn = $DIGEST2; request = $DIGEST4 })
  3. provider-settled(responded($DIGEST3, "CHILD_DONE"))
  4. turn-finished(turn=$DIGEST2, outcome=completed)

Stage 2 — the re-drive gate. Lose the child's journal; the durable edge
survives in the parent. A fresh engine attaching the parent re-materializes
the child and submits its first turn again: same session id, same first-turn
id, byte-identical normalized transcript. The parent's wait parks until the
re-driven child settles and integrates its result.

  $ rm -rf "$XDG_DATA_HOME/mentat/sessions/$CHILD" "$XDG_DATA_HOME/mentat/sessions/$CHILD.lock"
  $ cat > stage2.jsonl <<JSONL
  > {"expect":{"body_contains":["PLEASE_REDRIVE"],"body_not_contains":["wt-call"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"wt-item","call_id":"wt-call","name":"wait","arguments":"{\"children\":[\"$DELEG\"]}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_REDRIVE"]},"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["wt-call"]},"response":{"id":"r4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"REDRIVEN"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage2.jsonl capture2 port2
  $ start_daemon
  $ mentat run resume parent "PLEASE_REDRIVE" --attach --json --cwd "$PWD/work" >stage2.out 2>stage2.err
  $ wait_fake_server
  $ mentat_cram subst 't-[0-9]{13}-[0-9a-f]{4}' 't-TURN' <stage2.out
  {"schema_version":1,"type":"run.started","session_id":"parent","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"parent"}
  {"schema_version":1,"type":"turn.started","session_id":"parent","turn_id":"t-TURN","mode":"build","origin":"user","model":"openai/responses:gpt-5.6-sol"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"RED"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"RIV"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"EN"}
  {"schema_version":1,"type":"turn.finished","session_id":"parent","outcome":"completed","text":"REDRIVEN"}

The wait integrated the re-driven child's answer: exactly one captured
request — the continuation after the wait settled — carries the child result.

  $ grep -l 'CHILD_DONE' capture2/request-*.json | wc -l | tr -d ' '
  1

The re-materialized child: the store holds exactly one child session
directory, under the original id; the first-turn id was re-minted
identically; the normalized transcript is byte-identical to the first
materialization.

  $ wait_child "$CHILD" 1
  $ wait_child_exit "$CHILD"
  $ stop_daemon
  $ ls "$XDG_DATA_HOME/mentat/sessions/" | grep -cE '^sub-[0-9a-f]+$'
  1
  $ ls "$XDG_DATA_HOME/mentat/sessions/" | grep -c "^$CHILD$"
  1
  $ mentat session export "$CHILD" --format json --cwd "$PWD/work" >child2.ndjson
  $ T2=$(sed -n '2p' child2.ndjson | mentat_cram json '.document.events[0].turn.id')
  $ [ "$T1" = "$T2" ] && echo first-turn-id-re-minted-identically
  first-turn-id-re-minted-identically
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" | censor >child2.transcript
  $ diff child1.transcript child2.transcript && echo transcripts-identical
  transcripts-identical

Stage 3 — messages. send_message records a context delivery (a queue entry
the idle child consumes as its own turn); follow_up prompts the child
directly. Both address the child by the delegation id from the receipt, and
both keep driving inside the daemon after the parent's turn settles.

  $ cat > stage3.jsonl <<JSONL
  > {"expect":{"body_contains":["PLEASE_MESSAGE"],"body_not_contains":["sm-call"]},"response":{"id":"r5","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sm-item","call_id":"sm-call","name":"send_message","arguments":"{\"child\":\"$DELEG\",\"message\":\"extra context\"}"}]}}
  > {"expect":{"body_contains":["extra context"],"body_not_contains":["PLEASE_MESSAGE"]},"response":{"id":"rc3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_CONTEXT_SEEN"}]}]}}
  > {"expect":{"body_contains":["sm-call"],"body_not_contains":["fu-call"]},"response":{"id":"r6","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"fu-item","call_id":"fu-call","name":"follow_up","arguments":"{\"child\":\"$DELEG\",\"message\":\"one more thing\"}"}]}}
  > {"expect":{"body_contains":["one more thing"],"body_not_contains":["PLEASE_MESSAGE"]},"response":{"id":"rc4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_FOLLOWUP_DONE"}]}]}}
  > {"expect":{"body_contains":["fu-call"]},"response":{"id":"r7","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"PARENT_DONE"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage3.jsonl capture3 port3
  $ start_daemon
  $ mentat run resume parent "PLEASE_MESSAGE" --attach --json --cwd "$PWD/work" >stage3.out 2>stage3.err
  $ wait_fake_server
  $ mentat_cram subst 't-[0-9]{13}-[0-9a-f]{4}' 't-TURN' <stage3.out
  {"schema_version":1,"type":"run.started","session_id":"parent","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"parent"}
  {"schema_version":1,"type":"turn.started","session_id":"parent","turn_id":"t-TURN","mode":"build","origin":"user","model":"openai/responses:gpt-5.6-sol"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"PARE"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"NT_D"}
  {"schema_version":1,"type":"turn.text.delta","session_id":"parent","turn_id":"t-TURN","text":"ONE"}
  {"schema_version":1,"type":"turn.finished","session_id":"parent","outcome":"completed","text":"PARENT_DONE"}

Both deliveries were recorded against the delegation handle: the recording
receipts ride the parent's continuation requests (the follow-up's recording
appears once; the message's appears there and in the transcript of the
request after it).

  $ grep -l "Message recorded for child $DELEG" capture3/request-*.json | wc -l | tr -d ' '
  2
  $ grep -l "Follow-up recorded for child $DELEG" capture3/request-*.json | wc -l | tr -d ' '
  1

The child ran both deliveries to completion — the context turn and the
follow-up turn (their relative order is scheduling-dependent, so the pin is
counts and contents, not order).

  $ wait_child "$CHILD" 3
  $ stop_daemon
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" >child3.transcript
  $ grep -c 'turn-finished' child3.transcript
  3
  $ grep -c 'outcome=completed' child3.transcript
  3
  $ grep -c 'CHILD_CONTEXT_SEEN' child3.transcript
  1
  $ grep -c 'CHILD_FOLLOWUP_DONE' child3.transcript
  1

The parent's whole journey, normalized: three turns — the spawn with its
recorded edge and receipt, the wait that integrated the re-driven child, and
the two message recordings.

  $ mentat session export parent --format text --cwd "$PWD/work" | mentat_cram subst 't-[0-9]{13}-[0-9a-f]{4}' 't-TURN' | censor
  session parent
  phase: idle
  lifecycle: active
  cwd: $TESTCASE_ROOT/work
  events: 25
  1. turn-started({ id = t-TURN; origin = user; input = user[1 content block(s)]; model = openai/responses:gpt-5.6-sol })
  2. provider-requested({ id = $DIGEST1; turn = t-TURN; request = $DIGEST2 })
  3. provider-settled(responded($DIGEST1, ""))
  4. delegation-recorded({ id = $DIGEST3; child = sub-$DIGEST4 })
  5. message-appended(tool-result)
  6. provider-requested({ id = $DIGEST5; turn = t-TURN; request = $DIGEST6 })
  7. provider-settled(responded($DIGEST5, "SPAWNED"))
  8. turn-finished(turn=t-TURN, outcome=completed)
  9. turn-started({ id = t-TURN; origin = user; input = user[1 content block(s)]; model = openai/responses:gpt-5.6-sol })
  10. provider-requested({ id = $DIGEST7; turn = t-TURN; request = $DIGEST8 })
  11. provider-settled(responded($DIGEST7, ""))
  12. message-appended(tool-result)
  13. provider-requested({ id = $DIGEST9; turn = t-TURN; request = $DIGEST10 })
  14. provider-settled(responded($DIGEST9, "REDRIVEN"))
  15. turn-finished(turn=t-TURN, outcome=completed)
  16. turn-started({ id = t-TURN; origin = user; input = user[1 content block(s)]; model = openai/responses:gpt-5.6-sol })
  17. provider-requested({ id = $DIGEST11; turn = t-TURN; request = $DIGEST12 })
  18. provider-settled(responded($DIGEST11, ""))
  19. message-appended(tool-result)
  20. provider-requested({ id = $DIGEST13; turn = t-TURN; request = $DIGEST14 })
  21. provider-settled(responded($DIGEST13, ""))
  22. message-appended(tool-result)
  23. provider-requested({ id = $DIGEST15; turn = t-TURN; request = $DIGEST16 })
  24. provider-settled(responded($DIGEST15, "PARENT_DONE"))
  25. turn-finished(turn=t-TURN, outcome=completed)
