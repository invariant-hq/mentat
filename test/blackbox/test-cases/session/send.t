The owner's mail surface. `mentat session send` lands text durably in a
session's next-turn queue as the owner — no origin member, absence is the one
spelling of "the owner sent this" — through the broker's one delivery loop.
A dormant target takes the fence-held append; a running session's agent
holds its fence under the serving label and serves its derived socket, so
the same send crosses the wire mid-turn instead of dying against the held
fence.
Sending never wakes and never interrupts: the dormant session stays dormant,
and the live turn never sees the mail — it is read at the next turn
boundary. A missing session is a loud nonzero.

The sessions work in a workspace subdirectory; the fixture, marker, and
capture files live outside it so the turns drain no workspace notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ SOCK_BASE="$(child_sock_base)"

A durable allow rule lets the held turn run its shell tool unattended.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

Dormant delivery: settle a session, mail it, and read the fact.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first errand"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SETTLED"}]}]}}
  > JSONL
  $ start_fake_openai stage1.jsonl capture1 port1
  $ mentat run start --id dormant "first errand" --cwd "$PWD/work" 2>/dev/null
  SETTLED
  $ wait_fake_server
  $ wait_child_exit dormant
  $ mentat session send dormant "psst secret mail" --cwd "$PWD/work"
  delivered dormant
  $ DOC="$XDG_DATA_HOME/mentat/sessions/dormant/session.json"
  $ grep -o 'queue_updated' "$DOC" | wc -l | tr -d ' '
  1

Delivery is not a wake: the dormant session gained the queue fact and
nothing else — still exactly one finished turn.

  $ grep -o 'turn_finished' "$DOC" | wc -l | tr -d ' '
  1

The mail is read at the session's next run: attaching consumes the entry as
its own turn, whose request carries the message body. The resume's own
prompt contends with that consumption, so its exit is not part of the pin —
the consumption request reaching the model is.

  $ cat > stage2.jsonl <<'JSONL'
  > {"expect":{"body_contains":["psst secret mail"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"PSST_SEEN"}]}]}}
  > JSONL
  $ start_fake_openai stage2.jsonl capture2 port2
  $ mentat run resume dormant "unrelated nudge" --cwd "$PWD/work" >/dev/null 2>&1 || true
  $ wait_fake_server
  $ grep -l 'psst secret mail' capture2/request-*.json | wc -l | tr -d ' '
  1

A missing session is a loud nonzero, and nothing pretends to retry.

  $ mentat session send no-such-session "hello?" --cwd "$PWD/work" 2>&1 | censor
  mentat: session not found: no-such-session
  [1]

Live delivery over the agent's endpoint: a foreground `mentat run` holds
the turn open on a gated shell tool — the session's fence held the whole
time by its agent — and the send still answers delivered: the agent serves
the session's derived socket while driving, so the entry crosses the wire
into the live journal instead of burning its budget against the held fence.

  $ cat > stage3.jsonl <<'JSONL'
  > {"expect":{"body_contains":["hold the line"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"hold-item","call_id":"hold-call","name":"shell","arguments":"{\"command\":\"echo started > ../held-started && while [ ! -f ../go ]; do sleep 0.1; done && echo WAITED\"}"}]}}
  > {"expect":{"body_contains":["WAITED"],"body_not_contains":["mid-turn mail"]},"response":{"id":"r4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"HELD_DONE"}]}]}}
  > JSONL
  $ start_fake_openai stage3.jsonl capture3 port3
  $ mentat run start --id held "hold the line" --cwd "$PWD/work" >held.out 2>held.err &
  $ RUN_PID=$!
  $ wait_for_file held-started
  $ mentat session send held "mid-turn mail" --cwd "$PWD/work"
  delivered held
  $ HDOC="$XDG_DATA_HOME/mentat/sessions/held/session.json"
  $ grep -o 'queue_updated' "$HDOC" | wc -l | tr -d ' '
  1

The held turn never saw the mail: its continuation request excludes it (the
stage-3 fixture's second expectation), and the turn completes as scripted.
The queued entry outlives this run for whatever next runs the session.

  $ touch go
  $ wait "$RUN_PID"
  $ grep -c 'HELD_DONE' held.out
  1
