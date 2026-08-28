The shell tool's child carries the user's dune and OCaml configuration. Dune
folds its shared-cache mode, profile, sandboxing mode and `DUNE_CONFIG__*`
overrides into the digest of every rule, so a command that saw a different
configuration from the shell the user builds from would re-execute the user's
whole build and have its own re-executed back on the next manual one. The whole
`DUNE_*`, `OCAML*` and `CAML*` families reach the child verbatim; the handles
dune assigns to its own actions, `INSIDE_DUNE`, and every other ambient
variable do not. The suite's unconfined posture keeps this host-independent:
every route receives the same constructed environment.

  $ use_trusted_workspace
  $ cat > env.jsonl <<'JSONL'
  > {"response":{"id":"e1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"i1","call_id":"ec1","name":"shell","arguments":"{\"command\":\"env | grep -E '^(DUNE_CACHE|DUNE_PROFILE|DUNE_CONFIG__BACKGROUND_DIGESTS|OCAMLPARAM|DUNE_ACTION_TRACE_DIR|INSIDE_DUNE|AMBIENT_SECRET)=' | sort\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","ec1","DUNE_CACHE=enabled-except-user-rules"]},"response":{"id":"e2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL
  $ start_fake_openai env.jsonl

The shell is pinned to /bin/sh for a host-independent command runner. The
configuration family is exported the way a shell profile would; the action
handle and the secret stand in for what must stay behind.

  $ DUNE_CACHE=enabled-except-user-rules DUNE_PROFILE=release \
  >   DUNE_CONFIG__BACKGROUND_DIGESTS=disabled OCAMLPARAM=_,w=+a \
  >   DUNE_ACTION_TRACE_DIR=/nope/trace INSIDE_DUNE=1 AMBIENT_SECRET=hunter2 \
  >   MENTAT_SHELL=/bin/sh mentat run start --json --permission bypass --id env "e" >run.out 2>/dev/null; echo exit:$?
  exit:0
  $ wait_fake_server
  $ grep '"type":"tool.finished"' run.out | mentat_cram json .outcome
  returned

The configuration reached the command.

  $ grep -o 'DUNE_CACHE=enabled-except-user-rules' capture/request-2.json
  DUNE_CACHE=enabled-except-user-rules
  $ grep -o 'DUNE_PROFILE=release' capture/request-2.json
  DUNE_PROFILE=release
  $ grep -o 'DUNE_CONFIG__BACKGROUND_DIGESTS=disabled' capture/request-2.json
  DUNE_CONFIG__BACKGROUND_DIGESTS=disabled
  $ grep -o 'OCAMLPARAM=_,w=+a' capture/request-2.json
  OCAMLPARAM=_,w=+a

The running-instance handles and the unrelated secret did not.

  $ grep -c 'DUNE_ACTION_TRACE_DIR=\|INSIDE_DUNE=\|AMBIENT_SECRET=' capture/request-2.json
  0
  [1]

The posture is a choice: `sandbox.env_inherit=all` (here through its
environment override) additionally inherits the rest of the ambient
environment — the floor excepted, which no setting subtracts from: an
arbitrary exported setting reaches the command, a secret-shaped name does
not.

  $ cat > env2.jsonl <<'JSONL'
  > {"response":{"id":"f1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"i2","call_id":"fc1","name":"shell","arguments":"{\"command\":\"env | grep -E '^(ARBITRARY_SETTING|MY_API_KEY)=' | sort\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","fc1"]},"response":{"id":"f2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL
  $ start_fake_openai env2.jsonl capture2 port2
  $ MENTAT_SANDBOX_ENV_INHERIT=all ARBITRARY_SETTING=zesty MY_API_KEY=hunter2 \
  >   MENTAT_SHELL=/bin/sh mentat run start --json --permission bypass --id env2 "e" >run2.out 2>/dev/null; echo exit:$?
  exit:0
  $ wait_fake_server
  $ grep -o 'ARBITRARY_SETTING=zesty' capture2/request-2.json
  ARBITRARY_SETTING=zesty
  $ grep -c 'MY_API_KEY=' capture2/request-2.json
  0
  [1]
