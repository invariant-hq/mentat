The lint runner: after each green build settle the configured lint command
runs from the workspace root, its compiler-shaped output parses into the
lint lane, and the lane's changes reach the model beside the build lane's.
A fake litany on PATH prints scripted blocks and exits per script, so every
arc runs hermetically; the fake dune serves the watch protocol as in
dune-own.t.

  $ use_trusted_workspace
  $ touch dune-project
  $ use_fake_dune
  $ export MENTAT_DUNE_RPC_QUIET_S=0
  $ export MENTAT_DUNE_RPC_RECONNECT_S=0.25
  $ cat > fake-bin/litany <<'SH'
  > #!/bin/sh
  > echo "$@" >> "$PWD/fake-litany-argv"
  > cat "$PWD/lint-output" 2>/dev/null
  > code=$(cat "$PWD/lint-exit" 2>/dev/null || echo 0)
  > exit "$code"
  > SH
  $ chmod +x fake-bin/litany
  $ printf clean > dune-state
  $ cat > lint-output <<'EOF'
  > File "lib/inventory.ml", line 5, characters 17-40:
  > Warning 12 [needless-list-length]: comparison through List.length is a needless emptiness test [needless-list-length]
  > File "lib/inventory.ml", line 7, characters 43-52:
  > Error: physical comparison has a non-immediate operand [suspicious-physical-equality]
  > EOF
  $ printf 1 > lint-exit

A green settle triggers one lint run; the findings ride the next request on
their own lane while the build lane stays clean.

  $ cat > lint.jsonl <<'JSONL'
  > {"expect":{"body_contains":["lint prompt"]},"response":{"id":"l1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-l1","call_id":"call-l1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -S _build/.rpc/dune && break; sleep 0.1; done; sleep 1\",\"description\":\"wait for the watch to come up\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-l1"]},"response":{"id":"l2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-l2","call_id":"call-l2","name":"shell","arguments":"{\"command\":\"sleep 2\",\"description\":\"cover the lint run\"}"}]}}
  > {"expect":{"body_contains":["2 findings (2 new)"]},"response":{"id":"l3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-l3","call_id":"call-l3","name":"shell","arguments":"{\"command\":\"printf failing > dune-state; sleep 1.5\",\"description\":\"break the build\"}"}]}}
  > {"expect":{"body_contains":["Build failing (1 error: 1 new)"]},"response":{"id":"l4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-l4","call_id":"call-l4","name":"shell","arguments":"{\"command\":\": > lint-output; printf 0 > lint-exit; printf clean > dune-state; sleep 2.5\",\"description\":\"fix the build and the findings\"}"}]}}
  > {"expect":{"body_contains":["Build recovered","Lint clean"]},"response":{"id":"l5","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"linted"}]}]}}
  > JSONL
  $ start_fake_openai lint.jsonl capture-lint port-lint
  $ MENTAT_DUNE_WATCH=auto mentat run "lint prompt" --cwd "$PWD" --permission bypass --id lint-turn 2>/dev/null
  linted
  $ wait_fake_server

Two lint runs: one per green settle — the red build in between triggered
nothing.

  $ wc -l < fake-litany-argv | tr -d ' '
  2

A missing linter is a normal state: with the command's program gone from
PATH, no runner exists, nothing is stated about lint, and the build lane is
untouched.

  $ rm fake-bin/litany fake-litany-argv
  $ printf failing > dune-state
  $ cat > nolint.jsonl <<'JSONL'
  > {"expect":{"body_contains":["nolint prompt"]},"response":{"id":"n1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-n1","call_id":"call-n1","name":"shell","arguments":"{\"command\":\"sleep 3\",\"description\":\"let the watch come up\"}"}]}}
  > {"expect":{"body_contains":["Build failing (1 error: 1 new)"]},"response":{"id":"n2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"no linter"}]}]}}
  > JSONL
  $ start_fake_openai nolint.jsonl capture-nolint port-nolint
  $ MENTAT_DUNE_WATCH=auto mentat run "nolint prompt" --cwd "$PWD" --permission bypass --id nolint-turn 2>/dev/null
  no linter
  $ wait_fake_server
  $ test -f fake-litany-argv
  [1]
  $ grep -c 'Lint' capture-nolint/request-2.json
  0
  [1]
