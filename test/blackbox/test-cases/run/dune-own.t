The build-watch supervisor owns the watch. A fake dune on PATH records the
exact argv it is spawned with and serves dune's poll protocol from its
private XDG_RUNTIME_DIR, so every arc runs hermetically: observe never
spawns; auto spawns once and the model hears the watch's own readings; a
life that dies before coming up is respawned after a second; two such
deaths in a row give up; and an already-answering socket is attached to as
a foreign watch, never fought for. The quiet window is zero because the
whole exchange is local and instantaneous.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat config set dune.lint_command '[]' >/dev/null
  $ touch dune-project
  $ use_fake_dune
  $ export MENTAT_DUNE_RPC_QUIET_S=0
  $ export MENTAT_DUNE_RPC_RECONNECT_S=0.25

Observe mode never spawns: no marker file appears, and with nothing
registered there is nothing to hear.

  $ cat > observe.jsonl <<'JSONL'
  > {"expect":{"body_contains":["observe prompt"]},"response":{"id":"o1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"observed"}]}]}}
  > JSONL
  $ start_fake_openai observe.jsonl capture-observe port-observe
  $ MENTAT_DUNE_WATCH=observe mentat run "observe prompt" --cwd "$PWD" --permission bypass --id observe-turn 2>/dev/null
  observed
  $ wait_fake_server
  $ wait_child_exit observe-turn
  $ test -f fake-dune-argv
  [1]

Auto spawns the watch through the sealed session route with the pinned
argv, targets from dune.targets. The spawned watch registers privately, the
host mirrors the entry, the observer attaches, and the turn's next request
carries the watch's own failing reading.

  $ printf failing > dune-state
  $ cat > own.jsonl <<'JSONL'
  > {"expect":{"body_contains":["own prompt"]},"response":{"id":"n1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-n1","call_id":"call-n1","name":"shell","arguments":"{\"command\":\"sleep 3\",\"description\":\"give the watch time to come up\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-n1"]},"response":{"id":"n2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"owned"}]}]}}
  > JSONL
  $ start_fake_openai own.jsonl capture-own port-own
  $ MENTAT_DUNE_WATCH=auto mentat run "own prompt" --cwd "$PWD" --permission bypass --id own-turn 2>/dev/null
  owned
  $ wait_fake_server
  $ wait_child_exit own-turn
  $ cat fake-dune-argv
  build --root . --watch @check
  $ grep -c 'Build failing (1 error: 1 new)' capture-own/request-2.json
  1

Quitting leaves no orphan: the watch was signalled (its socket and private
registry entry unlinked by its own exit handlers) and the host removed the
registry mirror.

  $ test -S _build/.rpc/dune
  [1]
  $ find data/dune/rpc -type f 2>/dev/null | wc -l | tr -d ' '
  0
  $ find .mentat/run -name '*.csexp' | wc -l | tr -d ' '
  0

A life that dies before coming up is respawned after a second: the first
spawn exits at once, the retry serves, and the marker holds exactly the two
spawns.

  $ rm -f fake-dune-argv dune-state
  $ printf 'exit-once:1' > fake-dune-mode
  $ cat > respawn.jsonl <<'JSONL'
  > {"expect":{"body_contains":["respawn prompt"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-r1","call_id":"call-r1","name":"shell","arguments":"{\"command\":\"sleep 3\",\"description\":\"cover the restart pause\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-r1"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"respawned"}]}]}}
  > JSONL
  $ start_fake_openai respawn.jsonl capture-respawn port-respawn
  $ MENTAT_DUNE_WATCH=auto mentat run "respawn prompt" --cwd "$PWD" --permission bypass --id respawn-turn 2>/dev/null
  respawned
  $ wait_fake_server
  $ wait_child_exit respawn-turn
  $ wc -l < fake-dune-argv | tr -d ' '
  2

Two consecutive lives dying before coming up exhaust the budget: the
supervisor gives up and never spawns a third.

  $ rm -f fake-dune-argv
  $ printf 'exit:1' > fake-dune-mode
  $ cat > giveup.jsonl <<'JSONL'
  > {"expect":{"body_contains":["giveup prompt"]},"response":{"id":"g1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-g1","call_id":"call-g1","name":"shell","arguments":"{\"command\":\"sleep 4\",\"description\":\"outlive the give-up budget\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-g1"]},"response":{"id":"g2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"gave up"}]}]}}
  > JSONL
  $ start_fake_openai giveup.jsonl capture-giveup port-giveup
  $ MENTAT_DUNE_WATCH=auto mentat run "giveup prompt" --cwd "$PWD" --permission bypass --id giveup-turn 2>/dev/null
  gave up
  $ wait_fake_server
  $ wait_child_exit giveup-turn
  $ wc -l < fake-dune-argv | tr -d ' '
  2

A stalled forwarded build is the hang's witness: a dune command that times
out while the watch holds the lock reports a stall, one bounded flush
verifies it — the wedged loop never answers — and the watch is restarted,
the next request carrying the restart notice. The fake in hang mode answers
its first flush (the self-test) and parks the rest; a forwarder into it
sleeps forever, as a build forwarded into a wedged watch would.

  $ rm -f fake-dune-argv
  $ printf hang > fake-dune-mode
  $ printf clean > dune-state
  $ cat > hang.jsonl <<'JSONL'
  > {"expect":{"body_contains":["hang prompt"]},"response":{"id":"h1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-h1","call_id":"call-h1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -S _build/.rpc/dune && break; sleep 0.1; done; sleep 1\",\"description\":\"wait for the watch to come up\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-h1"]},"response":{"id":"h2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-h2","call_id":"call-h2","name":"shell","arguments":"{\"command\":\"dune build @check\",\"timeout_ms\":1000,\"description\":\"forward a build into the wedged watch\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-h2"]},"response":{"id":"h3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-h3","call_id":"call-h3","name":"shell","arguments":"{\"command\":\"sleep 4\",\"description\":\"cover verification and the restart\"}"}]}}
  > {"expect":{"body_contains":["Build watch restarted (stopped responding to builds)"]},"response":{"id":"h4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hung"}]}]}}
  > JSONL
  $ start_fake_openai hang.jsonl capture-hang port-hang
  $ MENTAT_DUNE_WATCH_FLUSH_S=0.5 MENTAT_DUNE_WATCH=auto mentat run "hang prompt" --cwd "$PWD" --permission bypass --id hang-turn 2>/dev/null
  hung
  $ wait_fake_server
  $ wait_child_exit hang-turn

Three shim invocations: the first life, the hung forwarder, and the
respawned life the supervisor started after verification failed.

  $ wc -l < fake-dune-argv | tr -d ' '
  3

A stall whose verification completes is a slow build, not a hang: the same
timed-out dune command reports, the flush answers, and nothing restarts —
no notice, no third shim invocation.

  $ rm -f fake-dune-argv
  $ printf slow > fake-dune-mode
  $ cat > slow.jsonl <<'JSONL'
  > {"expect":{"body_contains":["slow prompt"]},"response":{"id":"s1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-s1","call_id":"call-s1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -S _build/.rpc/dune && break; sleep 0.1; done; sleep 1\",\"description\":\"wait for the watch to come up\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-s1"]},"response":{"id":"s2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-s2","call_id":"call-s2","name":"shell","arguments":"{\"command\":\"dune build @check\",\"timeout_ms\":1000,\"description\":\"forward a build into the slow watch\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-s2"]},"response":{"id":"s3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-s3","call_id":"call-s3","name":"shell","arguments":"{\"command\":\"sleep 2\",\"description\":\"cover the verification\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-s3"]},"response":{"id":"s4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"slow"}]}]}}
  > JSONL
  $ start_fake_openai slow.jsonl capture-slow port-slow
  $ MENTAT_DUNE_WATCH=auto mentat run "slow prompt" --cwd "$PWD" --permission bypass --id slow-turn 2>/dev/null
  slow
  $ wait_fake_server
  $ wait_child_exit slow-turn

Two shim invocations only — the first life and the forwarder; verification
cleared the report, so no respawn and no restart notice anywhere in the
turn.

  $ wc -l < fake-dune-argv | tr -d ' '
  2
  $ grep -c 'Build watch restarted' capture-slow/request-4.json
  0
  [1]

A fresh watch whose file watcher never answers its first flushes is
blocked, not slow: announced at once, no restart budget spent, one warning
notice — and never a second spawn.

  $ rm -f fake-dune-argv
  $ printf hang-flush > fake-dune-mode
  $ cat > blocked.jsonl <<'JSONL'
  > {"expect":{"body_contains":["blocked prompt"]},"response":{"id":"b1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-b1","call_id":"call-b1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -S _build/.rpc/dune && break; sleep 0.1; done; sleep 1\",\"description\":\"wait for the watch to spawn\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-b1"]},"response":{"id":"b2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-b2","call_id":"call-b2","name":"shell","arguments":"{\"command\":\"sleep 3\",\"description\":\"cover attach and the self-test\"}"}]}}
  > {"expect":{"body_contains":["Build watch off (file watcher blocked by the sandbox)"]},"response":{"id":"b3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"blocked"}]}]}}
  > JSONL
  $ start_fake_openai blocked.jsonl capture-blocked port-blocked
  $ MENTAT_DUNE_WATCH_FLUSH_S=0.5 MENTAT_DUNE_WATCH=auto mentat run "blocked prompt" --cwd "$PWD" --permission bypass --id blocked-turn 2>/dev/null
  blocked
  $ wait_fake_server
  $ wait_child_exit blocked-turn
  $ wc -l < fake-dune-argv | tr -d ' '
  1
  $ rm -f fake-dune-mode

A socket that already answers is a foreign watch: the supervisor attaches
instead of spawning — no marker file — and the model hears the foreign
watch's readings as build findings whatever their text: mentat echoes the
watch it observes, so even a lint-shaped head from someone's watch is that
watch's build error.

  $ rm -f fake-dune-argv fake-dune-mode
  $ printf marker > foreign-state
  $ start_fake_dune_at_root "$PWD/foreign-state"
  $ cat > foreign.jsonl <<'JSONL'
  > {"expect":{"body_contains":["foreign prompt"]},"response":{"id":"f1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-f1","call_id":"call-f1","name":"shell","arguments":"{\"command\":\"sleep 2\",\"description\":\"one claim to settle\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-f1"]},"response":{"id":"f2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"attached"}]}]}}
  > JSONL
  $ start_fake_openai foreign.jsonl capture-foreign port-foreign
  $ MENTAT_DUNE_WATCH=auto mentat run "foreign prompt" --cwd "$PWD" --permission bypass --id foreign-turn 2>/dev/null
  attached
  $ wait_fake_server
  $ wait_child_exit foreign-turn
  $ stop_fake_dune
  $ test -f fake-dune-argv
  [1]
  $ grep -c 'Build failing (1 error: 1 new)' capture-foreign/request-2.json
  1
