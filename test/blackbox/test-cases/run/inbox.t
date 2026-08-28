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
