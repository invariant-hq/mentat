The promptless run: `mentat run resume SESSION` with no PROMPT starts the
session's agent, lets the inbox run, shows the feed, and exits at
settlement. Nothing is submitted by the run itself — the agent's boot
attach consumes mail already durable in the journal as the session's next
turn. The response is held briefly so the follow provably attaches while
the mailed turn runs and the answer is shown.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"

Mail a dormant session: the send lands a durable queue entry and wakes
nothing.

  $ mentat session create --id inbox --cwd "$PWD" >/dev/null
  $ mentat session send inbox "mailed errand" --cwd "$PWD"
  delivered inbox
  $ DOC="$XDG_DATA_HOME/mentat/sessions/inbox/session.json"
  $ grep -q 'turn_started' "$DOC" || echo no-turns-yet
  no-turns-yet

The promptless run: the agent starts, the mailed turn runs and prints, and
the run exits 0 at settlement.

  $ cat > mail.jsonl <<'JSONL'
  > {"delay_ms":1500,"expect":{"body_contains":["mailed errand"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"MAIL_RAN"}]}]}}
  > JSONL
  $ start_fake_openai mail.jsonl
  $ mentat run resume inbox --cwd "$PWD" 2>/dev/null; echo "exit:$?"
  MAIL_RAN
  exit:0
  $ wait_fake_server
  $ wait_child_exit inbox

The mailed turn is durable: one settled queued-origin turn.

  $ grep -o 'turn_finished' "$DOC" | wc -l | tr -d ' '
  1

A second promptless run finds the session settled with nothing queued — a
clean no-op that starts nothing (the fixture is down, so any wrongly
started turn would fault loudly).

  $ mentat run resume inbox --cwd "$PWD" 2>&1; echo "exit:$?"
  mentat: session inbox is settled with nothing queued
  exit:0

The per-turn flags need a prompt to ride; promptless they refuse loudly.

  $ mentat run resume inbox --max-steps 3 --cwd "$PWD" 2>&1
  mentat: a promptless resume submits nothing; --json, --mode, --permission, --max-steps, --output-schema, and --image need a PROMPT
  [2]

The promptless form also rides --last: the newest resumable session
resolves, and the same settled no-op answers.

  $ mentat run resume --last --cwd "$PWD" 2>&1; echo "exit:$?"
  mentat: session inbox is settled with nothing queued
  exit:0

--model/--reasoning are spawn-scoped on the promptless path, not per-turn:
they ride the started agent's boot environment, so the mailed turn's
request carries the chosen effort.

  $ mentat session create --id inbox2 --cwd "$PWD" >/dev/null
  $ mentat session send inbox2 "second errand" --cwd "$PWD"
  delivered inbox2
  $ cat > mail2.jsonl <<'JSONL'
  > {"delay_ms":1500,"expect":{"body_contains":["second errand","\"reasoning\":{\"effort\":\"high\""]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"EFFORT_RODE_THE_SPAWN"}]}]}}
  > JSONL
  $ start_fake_openai mail2.jsonl capture2 port2
  $ mentat run resume inbox2 --reasoning high --cwd "$PWD" 2>/dev/null; echo "exit:$?"
  EFFORT_RODE_THE_SPAWN
  exit:0
  $ wait_fake_server
  $ wait_child_exit inbox2

A parked DORMANT session: the promptless run answers the park from the
durable journal — the waiting block and exit 3 — without starting an
agent. The parked agent is first killed hard and its endpoint residue
cleared, so the empty socket tree after the run proves nothing started.

  $ cat > ask.jsonl <<'JSONL'
  > {"expect":{"body_contains":["decide please","\"name\":\"ask_user\""]},"response":{"id":"a1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"a-item","call_id":"a-call","name":"ask_user","arguments":"{\"prompt\":\"Which one?\"}"}]}}
  > JSONL
  $ start_fake_openai ask.jsonl capture-ask port-ask
  $ mentat run start --id rec "decide please" --cwd "$PWD" >park.out 2>/dev/null; echo "exit:$?"
  exit:3
  $ wait_fake_server
  $ kill -9 "$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/rec/run.lock" | mentat_cram json .pid)"
  $ rm -rf "$SOCK_BASE/rec"
  $ mentat run resume rec --cwd "$PWD" >promptless-park.out 2>&1; echo "exit:$?"
  exit:3
  $ grep -E '^(Decision |Question: |Reply with:)' promptless-park.out | censor
  Decision $DIGEST (question)
  Question: Which one?
  Reply with:
  $ test ! -e "$SOCK_BASE/rec" && echo no-agent-started
  no-agent-started

The other trivially-known dormant reads start nothing either: a show and a
list over these dormant sessions leave the socket tree empty.

  $ mentat session show rec --cwd "$PWD" >/dev/null
  $ mentat session list --cwd "$PWD" >/dev/null
  $ ls "$SOCK_BASE" 2>/dev/null | wc -l | tr -d ' '
  0
