The build-watch supervisor owns the watch. A fake dune on PATH records the
exact argv it is spawned with and serves dune's poll protocol from its
private XDG_RUNTIME_DIR, so every arc runs hermetically: observe never
spawns; auto spawns once and the model hears the watch's own readings; a
life that dies before coming up is respawned after a second; two such
deaths in a row give up; and an already-answering socket is attached to as
a foreign watch, never fought for. The quiet window is zero because the
whole exchange is local and instantaneous.

  $ use_trusted_workspace
  $ touch dune-project
  $ use_fake_dune
  $ export MENTAT_DUNE_RPC_QUIET_S=0

Observe mode never spawns: no marker file appears, and with nothing
registered there is nothing to hear.

  $ cat > observe.jsonl <<'JSONL'
  > {"expect":{"body_contains":["observe prompt"]},"response":{"id":"o1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"observed"}]}]}}
  > JSONL
  $ start_fake_openai observe.jsonl capture-observe port-observe
  $ MENTAT_DUNE_WATCH=observe mentat run "observe prompt" --cwd "$PWD" --permission bypass --id observe-turn 2>/dev/null
  observed
  $ wait_fake_server
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
  $ wc -l < fake-dune-argv | tr -d ' '
  2

A socket that already answers is a foreign watch: the supervisor attaches
instead of spawning — no marker — and the model hears the foreign watch's
readings.

  $ rm -f fake-dune-argv fake-dune-mode
  $ printf failing > foreign-state
  $ start_fake_dune_at_root "$PWD/foreign-state"
  $ cat > foreign.jsonl <<'JSONL'
  > {"expect":{"body_contains":["foreign prompt"]},"response":{"id":"f1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-f1","call_id":"call-f1","name":"shell","arguments":"{\"command\":\"sleep 2\",\"description\":\"one claim to settle\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-f1"]},"response":{"id":"f2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"attached"}]}]}}
  > JSONL
  $ start_fake_openai foreign.jsonl capture-foreign port-foreign
  $ MENTAT_DUNE_WATCH=auto mentat run "foreign prompt" --cwd "$PWD" --permission bypass --id foreign-turn 2>/dev/null
  attached
  $ wait_fake_server
  $ stop_fake_dune
  $ test -f fake-dune-argv
  [1]
  $ grep -c 'Build failing (1 error: 1 new)' capture-foreign/request-2.json
  1
