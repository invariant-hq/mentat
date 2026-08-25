Workspace notices are the dune build-health channel: the adapter's drain source,
observed from an already-running `dune build --watch` through the Dune RPC. This
suite stays host-independent — no dune or compiler on PATH — and pins both
halves of the producer: the silent halves (it engages but says nothing when the
build is not observable, and the tooling gate suppresses it), and the positive
Failing half, driven by `fake_dune_rpc_server` — a hermetic stand-in that
registers a Dune RPC endpoint in the XDG registry and answers the real client
handshake with canned diagnostics, so a failing build can be observed without a
dune. The recovery/dedup transitions need verdict state carried ACROSS turns,
which a fresh headless `run` process does not have (each starts from the [Clean]
baseline); those stay in the manual recipe in the wave report.

A trusted OCaml workspace (a `dune-project` marker present) engages the producer:
`workspace.tooling` defaults to `auto`, which engages on the marker. With no
`dune build --watch` registered for this root, build health is `disconnected`,
which is not an error — so the turn's request carries NO `Workspace notices:`
prelude. The turn completes normally, proving the producer polls without hanging
or faulting when the endpoint is absent.

  $ use_trusted_workspace
  $ touch dune-project
  $ export MENTAT_DUNE_WATCH=observe
  $ cat > notices.jsonl <<'JSONL'
  > {"expect":{"body_contains":["silent prompt"]},"response":{"id":"n1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"quiet answer"}]}]}}
  > JSONL
  $ start_fake_openai notices.jsonl capture-silent port-silent
  $ mentat run "silent prompt" --cwd "$PWD" --id silent-turn 2>/dev/null
  quiet answer
  $ wait_fake_server
  $ grep -c 'Workspace notices' capture-silent/request-1.json
  0
  [1]

Turning `workspace.tooling` off suppresses the producer entirely (it is never
built), so the same marker-present workspace stays silent through a second turn.

  $ cat > off.jsonl <<'JSONL'
  > {"expect":{"body_contains":["tooling off prompt"]},"response":{"id":"n2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"off answer"}]}]}}
  > JSONL
  $ start_fake_openai off.jsonl capture-off port-off
  $ MENTAT_WORKSPACE_TOOLING=off mentat run "tooling off prompt" --cwd "$PWD" --id off-turn 2>/dev/null
  off answer
  $ wait_fake_server
  $ grep -c 'Workspace notices' capture-off/request-1.json
  0
  [1]

A failing build the producer CAN observe emits an Error notice into the turn's
request. `start_fake_dune failing` registers a Dune RPC endpoint for this root
serving one failing diagnostic set over the watch's own poll protocol. The
observer attaches lazily at the first drain, so the turn-prep request carries
nothing yet; the tool claim's settlement is the next drain — the boundary a
request all but always follows — and by then the attach loop holds a settled
reading, so the change law states the failure into request 2. The quiet window
is shrunk to zero because the fake's whole exchange is local and instantaneous.
No dune or compiler is on PATH — the endpoint is the fake alone.

  $ start_fake_dune failing
  $ cat > fail.jsonl <<'JSONL'
  > {"expect":{"body_contains":["failing prompt"]},"response":{"id":"n3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-n3","call_id":"call-n3","name":"shell","arguments":"{\"command\":\"printf probed\",\"description\":\"one claim to settle\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-n3"]},"response":{"id":"n4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"noticed"}]}]}}
  > JSONL
  $ start_fake_openai fail.jsonl capture-fail port-fail
  $ MENTAT_DUNE_RPC_QUIET_S=0 mentat run "failing prompt" --cwd "$PWD" --permission bypass --id fail-turn 2>/dev/null
  noticed
  $ wait_fake_server
  $ stop_fake_dune
  $ grep -c 'Workspace notices' capture-fail/request-1.json
  0
  [1]
  $ grep -c 'Workspace notices' capture-fail/request-2.json
  1
  $ grep -c 'Build failing (1 error: 1 new)' capture-fail/request-2.json
  1
  $ grep -c 'This expression has type string' capture-fail/request-2.json
  1
