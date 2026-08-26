Two daemon-lifecycle proofs the unit tests cannot reach, each over a real
process: a tool child does not inherit the daemon's claim descriptor, so a
crashed daemon's lock is truly released even while its child lives on
(`run_lock.mli` O_CLOEXEC); the on-close eviction sweep
spares an instance that is mid-feed, so an unrelated connection's close cannot
evict a live turn out from under it (the three-zeros guard).

The two proofs run sequentially against one hermetic store. Only one daemon may
claim a store at a time, so each proof stops its daemon before the next starts;
this shared cleanup is the EXIT backstop that reaps any daemon (store-scoped
`mentatd --stop`) and the long-lived orphan child a failing A8 could otherwise
leak.

  $ cleanup_all () {
  >   mentatd --stop >/dev/null 2>&1 || true
  >   [ -n "${MENTAT_DAEMON_PID:-}" ] && kill "$MENTAT_DAEMON_PID" 2>/dev/null
  >   [ -f succ.pid ] && kill -9 "$(cat succ.pid)" 2>/dev/null
  >   [ -f child.pid ] && kill -9 "$(cat child.pid)" 2>/dev/null
  >   true
  > }
  $ trap cleanup_all EXIT
  $ export MENTAT_NOW=1753000000000
  $ use_trusted_workspace

A8 — the O_CLOEXEC end-to-end proof.

The daemon captures its environment (config, fake provider, /bin/sh) at start, so
all are wired before it comes up. A durable config rule pre-allows shell
execution: a headless run over --attach cannot answer a permission prompt, and a
review posture set over the wire does not reach an unattended turn's sealed
contract, so a matched allow rule is how the tool runs without parking — which
isolates this proof from permission review entirely.

  $ export MENTAT_SHELL=/bin/sh
  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

One script serves three turns: the first calls the shell tool to launch a
background `sleep` detached from the tool's pipes (redirected to /dev/null so the
tool returns at once) and records its pid; the second closes that turn; the third
is the successor daemon's resume turn (proving the reclaimed daemon drives the
same session).

  $ cat > script8.jsonl <<'JSONL'
  > {"response":{"id":"s1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"i1","call_id":"c1","name":"shell","arguments":"{\"command\":\"sleep 3141592 </dev/null >/dev/null 2>&1 & echo $! > child.pid; echo started\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","started"]},"response":{"id":"s2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"spawned"}]}]}}
  > {"expect":{"body_contains":["continue"]},"response":{"id":"s3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"continued"}]}]}}
  > JSONL
  $ start_fake_openai script8.jsonl capture-a8 port-a8
  $ start_daemon

The turn is driven through the daemon; the daemon spawns the shell tool, whose
grandchild `sleep` outlives the tool. The turn completes on the model's message.

  $ mentat run start --attach --id sleeper "spawn a child" --cwd "$PWD" >run8.out 2>/dev/null
  $ grep -o spawned run8.out
  spawned

The child recorded its pid and is alive — a long-lived descendant of the daemon,
the case where an inherited lock descriptor would matter.

  $ test -s child.pid && echo have-pid
  have-pid
  $ kill -0 "$(cat child.pid)" 2>/dev/null && echo child-alive
  child-alive

The daemon is killed hard (SIGKILL) with the child still running. On macOS the
child is reparented to launchd and keeps living past its parent's death. Its pid
in the discovery file is recorded first, so a successor's fresh pid can be told
apart from the crashed one (the file itself is stale — kill -9 clears nothing).

  $ OLD_PID=$(grep -oE '"pid":[0-9]+' "$XDG_DATA_HOME/mentat/daemon/daemon.json" | grep -oE '[0-9]+')
  $ kill -9 "$MENTAT_DAEMON_PID"; wait "$MENTAT_DAEMON_PID" 2>/dev/null; true
  $ MENTAT_DAEMON_PID=
  $ kill -0 "$(cat child.pid)" 2>/dev/null && echo survives-parent
  survives-parent

The proof: a resume over --attach finds no live daemon (the socket is dead), so
it reclaims the store and spawns a successor. That reclaim can only converge if
the claim lock is free — and the lock is free only because the still-living tool
child did NOT inherit its descriptor (O_CLOEXEC). Were the descriptor inherited,
the child would hold the advisory lock past the crash and the fresh claim would
be Held, so the reclaim would never converge. The successor drives the SAME
session to completion (the third scripted turn), which also proves the run fence
was released for the same reason; and the discovery file now names a different
pid, so a genuinely new process claimed the store.

  $ mentat run resume sleeper "continue" --attach --cwd "$PWD" 2>/dev/null
  continued
  $ NEW_PID=$(grep -oE '"pid":[0-9]+' "$XDG_DATA_HOME/mentat/daemon/daemon.json" | grep -oE '[0-9]+')
  $ echo "$NEW_PID" > succ.pid
  $ [ -n "$NEW_PID" ] && [ "$OLD_PID" != "$NEW_PID" ] && echo reclaimed-by-fresh-daemon
  reclaimed-by-fresh-daemon

Tear A8 down completely so A1 opens a free claim: `mentatd --stop` unlinks the
discovery file, but a find-or-spawn'd successor is detached and does not always
stop on that alone, so the successor pid is killed directly (SIGKILL releases the
claim on death). The orphan sleep is reaped the same way. Bounded polls confirm
both are gone before the next proof — nothing leaks.

  $ mentatd --stop >/dev/null 2>&1
  $ kill -9 "$NEW_PID" 2>/dev/null; kill -9 "$(cat child.pid)" 2>/dev/null; wait "$NEW_PID" 2>/dev/null; true
  $ for i in 1 2 3 4 5 6 7 8 9 10; do ps -p "$NEW_PID" >/dev/null 2>&1 || break; sleep 0.2; done
  $ ps -p "$NEW_PID" >/dev/null 2>&1 && echo daemon-leaked || echo daemon-stopped
  daemon-stopped
  $ kill -0 "$(cat child.pid)" 2>/dev/null && echo orphan-leaked || echo orphan-reaped
  orphan-reaped
  $ rm -f child.pid succ.pid

A1 — the instance-sweep survival proof.

Two workspaces under the one store, each trusted before the daemon starts; the
daemon boots a per-workspace instance on demand and one on-close sweep can see
both. A single fake, captured at start, answers workspace A's one slow turn
(workspace B's list never reaches a provider). The response holds ten seconds so
B's sweep provably fires while A is still mid-feed.

  $ mkdir -p ws-a/.git ws-b/.git
  $ mentat trust ws-a >/dev/null
  $ mentat trust ws-b >/dev/null
  $ cat > script1.jsonl <<'JSONL'
  > {"delay_ms":10000,"expect":{"body_contains":["slow work"]},"response":{"id":"a1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"slow-a-done"}]}]}}
  > JSONL
  $ start_fake_openai script1.jsonl capture-a1 port-a1
  $ start_daemon

Start A's slow run in the background and wait until its request reaches the fake.
The capture file is written before the ten-second hold, so this is a
happens-before edge: A is provably in-turn — its wire connection bound to A's
instance and its follow feed retaining that instance's hub — before anything on B
runs.

  $ mentat run start --attach --id slow-a "slow work" --cwd "$PWD/ws-a" >a.out 2>&1 &
  $ A_PID=$!
  $ wait_for_file capture-a1/request-1.json

With A mid-feed, open and close a second connection on workspace B. Its close
fires the daemon's on-close eviction sweep, which folds over every instance —
including A's. That this list returns (exit 0) while A is still inside its
ten-second hold is itself the concurrency: B was served, swept, and gone before
A's turn ended.

  $ mentat session list --attach --cwd "$PWD/ws-b" >/dev/null 2>&1; echo b-swept:$?
  b-swept:0

A's in-flight turn completes correctly: the sweep spared A's instance because the
three-zeros guard counts its bound connection and its retained hub, so the
instance was not evicted under its own feed. The answer is the model's, intact.

  $ wait "$A_PID"
  $ grep -o slow-a-done a.out
  slow-a-done

  $ stop_daemon
