The agent endpoint is confined to its one purpose: the session cone answers
only for the served session and its own delegation subtree, and the two
session-scoped settings writes (set_model, set_permission_review) pass under
the same membership guard — the one confinement door. A foreign session id
is refused, never resolved against the shared store. The other cones —
accounts, the sessionless settings, lifecycle, review, workspace — stay
refused whole in the server; no product client sends them to a per-session
endpoint any more (the frontends answer them locally), so this file probes
what a client can still reach over the wire.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ SOCK_BASE="$(child_sock_base)"

A durable allow rule lets the delegated child below run its shell tool
unattended.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

Stage 1 — the foreign-session refusal, over a real serve endpoint. Serve
beta by hand at ALPHA's derived socket directory — the harness's way to aim
an ordinary client at an endpoint serving a different session — and resume
alpha: the client dials alpha's derived socket, reaches beta's server, and
the confinement refuses the foreign id. A virgin root with no mail keeps
serving until something drives it, so beta's server stays up for the probes
and is stopped by signal at the end of the stage.

  $ mentat session create --id alpha --cwd "$PWD/work" >/dev/null
  $ mentat session create --id beta --cwd "$PWD/work" >/dev/null
  $ mkdir -p "$SOCK_BASE/alpha"
  $ chmod 0700 "$SOCK_BASE/alpha"
  $ mentat serve --session beta --socket-dir "$SOCK_BASE/alpha" --cwd "$PWD/work" >beta-serve.out 2>&1 &
  $ BETA_PID=$!
  $ wait_for_file beta-serve.out

A session-cone call for alpha at beta's endpoint is refused without ever
reaching a driver.

  $ mentat run resume alpha "hi" --json --cwd "$PWD/work" 2>&1 | censor
  {"schema_version":1,"type":"run.started","session_id":"alpha","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"alpha"}
  mentat: this server serves session beta and its delegation subtree, not alpha
  [1]

The door is member-guarded too: a session-scoped settings write for alpha
at beta's endpoint is the same refusal — the write rides the wire ahead of
the prompt, so it is the first thing refused.

  $ mentat run resume alpha --reasoning high "hi" --json --cwd "$PWD/work" 2>&1 | censor
  mentat: this server serves session beta and its delegation subtree, not alpha
  [1]
  $ kill "$BETA_PID" 2>/dev/null; wait "$BETA_PID" 2>/dev/null; true

Stage 2 — the positive controls over a spawned child. The parent's agent
spawns the child, whose task turn is held open by a gated shell tool so its
server stays up for the probes without linger pacing. The marker files are
written outside the workspace so the turns drain no notices.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started && while [ ! -f ../go ]; do sleep 0.1; done && echo WAITED\"}"}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ mentat run start --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ wait_for_file child-started

The child's own id passes the confinement and reaches the live driver,
whose Busy answer proves the contact (the child is mid-turn).

  $ mentat run resume "$CHILD" "DIRECT" --json --cwd "$PWD/work" 2>&1 | censor
  {"schema_version":1,"type":"run.started","session_id":"sub-$DIGEST1","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"sub-$DIGEST1"}
  mentat: turn $DIGEST2 is still active
  [2]

Release the tool and let the child settle and both agents exit cleanly.

  $ touch go
  $ wait_fake_server
  $ wait_child "$CHILD" 1
  $ wait_child_exit "$CHILD"
  $ wait_child_exit parent

Stage 3 — the door admits the served session's own settings write. A resume
of alpha with a session-scoped selection starts alpha's agent and sets the
overlay over the wire; the turn's provider request carries the chosen
reasoning effort, which is only possible if the write landed on the driving
process.

  $ cat > stage3.jsonl <<'JSONL'
  > {"expect":{"body_contains":["MODEL_PLEASE","\"reasoning\":{\"effort\":\"high\""]},"response":{"id":"m1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"EFFORT_SET"}]}]}}
  > JSONL
  $ start_fake_openai stage3.jsonl capture3 port3
  $ mentat run resume alpha --reasoning high "MODEL_PLEASE" --cwd "$PWD/work" 2>/dev/null
  EFFORT_SET
  $ wait_fake_server
  $ wait_child alpha 1
  $ wait_child_exit alpha
