The claim across a daemon crash. POSIX record locks are owned by the
process: the kernel releases the daemon's claim the instant it dies,
whatever descriptors its children carry — so the truths this test can pin
are that the spawned agent survives the daemon's death as its own
process, that a successor daemon claims the store immediately, and that
the successor's residue sweep spares the living agent's endpoint. The
producer is the daemon-as-frontend path: a browser prompt against a
dormant session starts the session's agent through the daemon's broker.

  $ use_trusted_workspace
  $ SOCK_BASE=$(child_sock_base)
  $ export MENTAT_CHILD_LINGER=60
  $ cleanup_all () {
  >   mentatd stop >/dev/null 2>&1 || true
  >   [ -n "${MENTAT_DAEMON_PID:-}" ] && kill -9 "$MENTAT_DAEMON_PID" 2>/dev/null
  >   [ -f agent.pid ] && kill -9 "$(cat agent.pid)" 2>/dev/null
  >   true
  > }
  $ trap cleanup_all EXIT

The daemon serves the browser frontend; the cookie exchange is web.t's
subject, used here only for a credentialed POST.

  $ mentatd --web >web.out 2>&1 &
  $ MENTAT_DAEMON_PID=$!
  $ wait_for_file "$XDG_DATA_HOME/mentat/daemon/daemon.json"
  $ for _ in $(seq 1 100); do grep -q 'mentat web: open' web.out && break; sleep 0.1; done
  $ URL=$(sed -n 's/^mentat web: open //p' web.out)
  $ PORT=$(printf '%s' "$URL" | sed -E 's#.*127\.0\.0\.1:([0-9]+)/.*#\1#')
  $ BASE="http://127.0.0.1:$PORT"
  $ ORIGIN="Origin: http://127.0.0.1:$PORT"
  $ curl -sS -c jar -o /dev/null "$URL"

A browser action: create a session, then prompt it. The prompt is the
session-scoped call, so the daemon starts the session's agent through its
broker and dials it. No provider is configured — the turn faults in the
feed — but the spawn is the subject, and the settled agent lingers under
the raised MENTAT_CHILD_LINGER.

  $ curl -sS -b jar -H "$ORIGIN" --data-urlencode 'submit=1' -D hdr -o /dev/null "$BASE/sessions"
  $ SES=$(grep -i '^location:' hdr | tr -d '\r' | awk '{print $2}' | sed 's#/session/##')
  $ curl -sS -b jar -H "$ORIGIN" --data-urlencode 'prompt=hello' -o /dev/null "$BASE/session/$SES/prompt"
  $ for _ in $(seq 1 100); do [ -e "$SOCK_BASE/$SES" ] && break; sleep 0.1; done
  $ test -e "$SOCK_BASE/$SES" && echo agent-endpoint-bound
  agent-endpoint-bound
  $ head -n 1 "$XDG_DATA_HOME/mentat/sessions/$SES/run.lock" | mentat_cram json .pid > agent.pid
  $ kill -0 "$(cat agent.pid)" && echo agent-alive
  agent-alive

The daemon dies hard with its spawned agent still running. The stale
discovery file names the dead pid — kill -9 clears nothing — so the old
pid is recorded first to tell the successor's fresh pid apart.

  $ OLD_PID=$(grep -oE '"pid":[0-9]+' "$XDG_DATA_HOME/mentat/daemon/daemon.json" | grep -oE '[0-9]+')
  $ kill -9 "$MENTAT_DAEMON_PID"; wait "$MENTAT_DAEMON_PID" 2>/dev/null; true
  $ MENTAT_DAEMON_PID=
  $ kill -0 "$(cat agent.pid)" && echo agent-survives-daemon
  agent-survives-daemon

A successor daemon claims the store immediately: the kernel released the
dead daemon's record lock at the crash, and the surviving agent holds no
claim of its own to stand in the way.

  $ mentatd >successor.out 2>&1 &
  $ MENTAT_DAEMON_PID=$!
  $ NEW_PID=
  $ for _ in $(seq 1 100); do NEW_PID=$(grep -oE '"pid":[0-9]+' "$XDG_DATA_HOME/mentat/daemon/daemon.json" 2>/dev/null | grep -oE '[0-9]+'); [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && break; sleep 0.1; done
  $ [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && echo reclaimed-by-fresh-daemon
  reclaimed-by-fresh-daemon

The successor's boot residue sweep spared the live agent: its session is
stored, so its endpoint leaf is claimed and survives — and the spared
endpoint is genuinely routable: a mid-linger mail delivers only over the
wire into the surviving agent's own socket.

  $ test -e "$SOCK_BASE/$SES" && echo endpoint-survives-boot
  endpoint-survives-boot
  $ mentat session send "$SES" "mail for the survivor" --cwd "$PWD" | sed "s/$SES/SES/"
  delivered SES
  $ head -n 1 "$XDG_DATA_HOME/mentat/sessions/$SES/run.lock" | mentat_cram json .pid | diff - agent.pid && echo same-surviving-agent
  same-surviving-agent

Teardown: stop the successor, reap the lingering agent.

  $ mentatd stop
  $ kill -9 "$(cat agent.pid)" 2>/dev/null; true
