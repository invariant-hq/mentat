The lint runner: after each green build settle the configured lint command
runs from the workspace root, its compiler-shaped output parses into the
lint lane, and the lane's changes reach the model beside the build lane's.
A fake linter on PATH prints scripted blocks and exits per script, so every
arc runs hermetically; the fake dune serves the watch protocol as in
dune-own.t.

  $ use_trusted_workspace
  $ mentat config set dune.lint_command '["lintprobe", "check"]' >/dev/null
  $ touch dune-project
  $ use_fake_dune
  $ export MENTAT_DUNE_RPC_QUIET_S=0
  $ export MENTAT_DUNE_RPC_RECONNECT_S=0.25
  $ cat > fake-bin/lintprobe <<'SH'
  > #!/bin/sh
  > echo "$@" >> "$PWD/fake-litany-argv"
  > cat "$PWD/lint-output" 2>/dev/null
  > code=$(cat "$PWD/lint-exit" 2>/dev/null || echo 0)
  > exit "$code"
  > SH
  $ chmod +x fake-bin/lintprobe
  $ printf clean > dune-state
  $ cat > lint-output <<'EOF'
  > File "lib/inventory.ml", line 5, characters 17-40:
  > Warning 12 [needless-list-length]: comparison through List.length is a needless emptiness test [needless-list-length]
  > File "lib/inventory.ml", line 7, characters 43-52:
  > Error: physical comparison has a non-immediate operand [suspicious-physical-equality]
  > EOF
  $ printf 1 > lint-exit

A green settle triggers one lint run; the findings ride the next request
on their own lane while the build lane stays clean. A crashed linter
(non-zero exit, no report) then keeps the lane's last word — the stated
findings are neither retracted nor replaced by a clean no linter earned —
and a later completed clean run states Lint clean.

  $ cat > lint.jsonl <<'JSONL'
  > {"expect":{"body_contains":["lint prompt"]},"response":{"id":"l1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-l1","call_id":"call-l1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -f fake-litany-argv && break; sleep 0.1; done; sleep 1\",\"description\":\"wait for the watch and the first lint run\"}"}]}}
  > {"expect":{"body_contains":["2 findings (2 new)"]},"response":{"id":"l2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-l2","call_id":"call-l2","name":"shell","arguments":"{\"command\":\": > lint-output; printf 2 > lint-exit; printf failing > dune-state; sleep 1.5; printf clean > dune-state; for i in $(seq 100); do test $(wc -l < fake-litany-argv) -ge 2 && break; sleep 0.1; done; sleep 1\",\"description\":\"crash the linter across a red-green cycle\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-l2"]},"response":{"id":"l3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-l3","call_id":"call-l3","name":"shell","arguments":"{\"command\":\"printf 0 > lint-exit; printf failing > dune-state; sleep 1.5; printf clean > dune-state; for i in $(seq 100); do test $(wc -l < fake-litany-argv) -ge 3 && break; sleep 0.1; done; sleep 1\",\"description\":\"fix the linter across another red-green cycle\"}"}]}}
  > {"expect":{"body_contains":["Lint clean"]},"response":{"id":"l4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"linted"}]}]}}
  > JSONL
  $ start_fake_openai lint.jsonl capture-lint port-lint
  $ MENTAT_DUNE_WATCH=auto mentat run "lint prompt" --cwd "$PWD" --permission bypass --id lint-turn 2>/dev/null
  linted
  $ wait_fake_server

Three lint runs, one per green settle. The crashed second run said nothing:
its request carries no Lint clean and no new findings — the lane held its
word until the completed third run earned the clean.

  $ wc -l < fake-litany-argv | tr -d ' '
  3
  $ grep -c 'Lint clean' capture-lint/request-3.json
  0
  [1]

A foreign watch's green settle is as good as our own: with someone else's
watch serving clean and no spawn of ours, the runner still lints on its
settle.

  $ printf clean > foreign-state
  $ start_fake_dune_at_root "$PWD/foreign-state"
  $ rm -f fake-dune-argv fake-litany-argv
  $ cat > lint-output <<'EOF'
  > File "lib/inventory.ml", line 5, characters 17-40:
  > Warning 12 [needless-list-length]: comparison through List.length is a needless emptiness test [needless-list-length]
  > EOF
  $ printf 1 > lint-exit
  $ cat > foreignlint.jsonl <<'JSONL'
  > {"expect":{"body_contains":["foreignlint prompt"]},"response":{"id":"f1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-f1","call_id":"call-f1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -f fake-litany-argv && break; sleep 0.1; done; sleep 1\",\"description\":\"wait for the foreign settle's lint run\"}"}]}}
  > {"expect":{"body_contains":["1 finding (1 new)"]},"response":{"id":"f2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"foreign linted"}]}]}}
  > JSONL
  $ start_fake_openai foreignlint.jsonl capture-foreignlint port-foreignlint
  $ MENTAT_DUNE_WATCH=auto mentat run "foreignlint prompt" --cwd "$PWD" --permission bypass --id foreignlint-turn 2>/dev/null
  foreign linted
  $ wait_fake_server
  $ stop_fake_dune
  $ test -f fake-dune-argv
  [1]

A linter off the PATH is the dune-pkg world: the resolver finds the built
binary in the lock universe's package store and runs it directly — no
dune in the lint path at all.

  $ rm fake-bin/lintprobe fake-litany-argv
  $ mkdir -p _build/_private/default/.pkg/lintprobe.1.0/target/bin
  $ cat > _build/_private/default/.pkg/lintprobe.1.0/target/bin/lintprobe <<SH
  > #!/bin/sh
  > echo "\$@" >> "$PWD/fake-litany-argv"
  > cat "$PWD/lint-output" 2>/dev/null
  > code=\$(cat "$PWD/lint-exit" 2>/dev/null || echo 0)
  > exit "\$code"
  > SH
  $ chmod +x _build/_private/default/.pkg/lintprobe.1.0/target/bin/lintprobe
  $ cat > lint-output <<'EOF'
  > File "lib/inventory.ml", line 5, characters 17-40:
  > Warning 12 [needless-list-length]: comparison through List.length is a needless emptiness test [needless-list-length]
  > EOF
  $ printf 1 > lint-exit
  $ printf clean > dune-state
  $ cat > lockbin.jsonl <<'JSONL'
  > {"expect":{"body_contains":["lockbin prompt"]},"response":{"id":"k1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-k1","call_id":"call-k1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -S _build/.rpc/dune && break; sleep 0.1; done; for i in $(seq 200); do test -f fake-litany-argv && break; sleep 0.1; done; sleep 1\",\"description\":\"wait for the watch and the lint run's evidence\"}"}]}}
  > {"expect":{"body_contains":["1 finding (1 new)"]},"response":{"id":"k2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"lock linted"}]}]}}
  > JSONL
  $ start_fake_openai lockbin.jsonl capture-lockbin port-lockbin
  $ MENTAT_DUNE_WATCH=auto mentat run "lockbin prompt" --cwd "$PWD" --permission bypass --id lockbin-turn 2>/dev/null
  lock linted
  $ wait_fake_server
  $ cat fake-litany-argv
  check
  $ test -f fake-dune-exec-argv
  [1]

A linter that resolves nowhere skips its settle and the lane keeps
waiting: no run, no findings, no death. When the binary appears
mid-session — a lock universe freshly built — the next green settle runs
it and states its findings.

  $ rm -rf _build/_private fake-litany-argv fake-dune-exec-argv
  $ printf clean > dune-state
  $ cat > nolint.jsonl <<'JSONL'
  > {"expect":{"body_contains":["nolint prompt"]},"response":{"id":"n1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-n1","call_id":"call-n1","name":"shell","arguments":"{\"command\":\"for i in $(seq 100); do test -S _build/.rpc/dune && break; sleep 0.1; done; sleep 2\",\"description\":\"wait for the watch and the skipped settle\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-n1"]},"response":{"id":"n2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-n2","call_id":"call-n2","name":"shell","arguments":"{\"command\":\"mkdir -p _build/_private/default/.pkg/lintprobe.1.0/target/bin; printf '#!/bin/sh\\necho \\\"$@\\\" >> fake-litany-argv\\ncat lint-output\\nexit 1\\n' > _build/_private/default/.pkg/lintprobe.1.0/target/bin/lintprobe; chmod +x _build/_private/default/.pkg/lintprobe.1.0/target/bin/lintprobe; printf failing > dune-state; sleep 1.5; printf clean > dune-state; for i in $(seq 100); do test -f fake-litany-argv && break; sleep 0.1; done; sleep 1\",\"description\":\"build the linter into the lock universe and settle again\"}"}]}}
  > {"expect":{"body_contains":["1 finding (1 new)"]},"response":{"id":"n3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"late linter"}]}]}}
  > JSONL
  $ start_fake_openai nolint.jsonl capture-nolint port-nolint
  $ MENTAT_DUNE_WATCH=auto mentat run "nolint prompt" --cwd "$PWD" --permission bypass --id nolint-turn 2>/dev/null
  late linter
  $ wait_fake_server

The first settle ran nothing; the appearance ran exactly once.

  $ grep -c check fake-litany-argv
  1
