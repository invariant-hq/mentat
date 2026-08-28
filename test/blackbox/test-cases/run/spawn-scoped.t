The spawn-scoped gate and the settings door against an agent that is
ALREADY serving. The spawn-scoped flags (--sandbox and kin) configure an
agent at its start; against a live agent they would silently not apply, so
they refuse loudly. The session-scoped settings writes (--reasoning and
kin) have a wire carrier — the confinement door — so they land on the live
agent without a restart. A raised linger keeps the settled agent provably
alive across the probes.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ export MENTAT_CHILD_LINGER=20

  $ cat > first.jsonl <<'JSONL'
  > {"expect":{"body_contains":["settle"]},"response":{"id":"g1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SETTLED"}]}]}}
  > JSONL
  $ start_fake_openai first.jsonl capture1 port1
  $ mentat run start --id gated "settle" --cwd "$PWD" 2>/dev/null
  SETTLED
  $ wait_fake_server
  $ PID1=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/gated/run.lock" | mentat_cram json .pid)

A spawn-scoped flag against the lingering live agent refuses, naming the
variable it would have configured — a safety posture must never silently
diverge from enforcement.

  $ mentat run resume gated --sandbox read-only "again" --cwd "$PWD" 2>&1
  mentat: sandbox: read-only (read project, network restricted)
  mentat: session gated's agent is already running; MENTAT_SANDBOX_MODE configures an agent at its start — let it idle out (or interrupt it) and re-run
  [2]

The settings door admits the session-scoped write on the SAME live agent:
the turn's request carries the chosen effort, and the fence's owner pid is
unchanged — no restart, no second spawn.

  $ cat > second.jsonl <<'JSONL'
  > {"expect":{"body_contains":["EFFORT_PLEASE","\"reasoning\":{\"effort\":\"high\""]},"response":{"id":"g2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"EFFORT_ON_LIVE"}]}]}}
  > JSONL
  $ start_fake_openai second.jsonl capture2 port2 --port "$(cat port1)"
  $ mentat run resume gated --reasoning high "EFFORT_PLEASE" --cwd "$PWD" 2>/dev/null
  EFFORT_ON_LIVE
  $ wait_fake_server
  $ PID2=$(head -n 1 "$XDG_DATA_HOME/mentat/sessions/gated/run.lock" | mentat_cram json .pid)
  $ [ "$PID1" = "$PID2" ] && echo same-live-agent
  same-live-agent

Wind down the long linger explicitly: a graceful stop removes the endpoint.

  $ kill "$PID2"
  $ wait_child_exit gated
