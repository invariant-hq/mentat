The child server's endpoint is confined to its one purpose: the session cone
answers only for the served child and its own delegation subtree, and every
other cone — accounts, settings, lifecycle, review, workspace — is refused
whole. MENTAT_DAEMON_SOCKET points the ordinary client straight at the
child's socket (no daemon.json read, no spawn), so each refusal is observed
over the same wire the daemon and broker speak. The positive control: the
child's own id is admitted past the confinement and reaches the live driver
(here mid-turn, so the driver's own Busy answer is the proof of contact).

The child is held mid-turn by a gated shell tool so its server stays up for
the probes without linger pacing. The sessions work in a workspace
subdirectory, and the tool's marker files are written outside it so the
turns drain no workspace notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ trap stop_daemon EXIT
  $ export MENTAT_CHILD_LINGER=0.2

A durable allow rule lets the delegated child run its shell tool unattended.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

The child choreography helpers — wait_child, wait_child_exit, and the
$SOCK_BASE capture below — live in setup.sh beside the daemon helpers.

Stage 1 — spawn, and hold the child mid-turn.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started && while [ ! -f ../go ]; do sleep 0.1; done && echo WAITED\"}"}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > {"expect":{"body_contains":["WAITED"]},"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ start_daemon
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat run start --attach --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ wait_for_file child-started
  $ SOCK="$SOCK_BASE/$CHILD/mentat.sock"

A foreign session id on the child's socket is refused — the parent's own
session, submitted straight at the child endpoint.

  $ MENTAT_DAEMON_SOCKET="$SOCK" mentat run resume parent "hi" --attach --json --cwd "$PWD/work" 2>&1 | censor
  {"schema_version":1,"type":"run.started","session_id":"parent","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"parent"}
  mentat: this server serves session sub-$DIGEST and its delegation subtree, not parent
  [1]

The lifecycle cone is refused whole.

  $ MENTAT_DAEMON_SOCKET="$SOCK" mentat session list --attach --cwd "$PWD/work" 2>&1 | censor
  mentat: this server serves one delegated session; accounts, settings, lifecycle, review, and workspace operations belong to the daemon
  [1]

The positive control: the child's own id passes the confinement and reaches
the live driver, whose Busy answer proves the contact (the child is
mid-turn).

  $ MENTAT_DAEMON_SOCKET="$SOCK" mentat run resume "$CHILD" "DIRECT" --attach --json --cwd "$PWD/work" 2>&1 | censor
  {"schema_version":1,"type":"run.started","session_id":"sub-$DIGEST1","sandbox":{"mode":"danger-full-access","read":"project","network":"restricted"},"trusted":true}
  {"schema_version":1,"type":"session.started","session_id":"sub-$DIGEST1"}
  mentat: turn $DIGEST2 is still active
  [2]

Release the tool and let the child settle and exit cleanly.

  $ touch go
  $ wait_fake_server
  $ wait_child "$CHILD" 1
  $ wait_child_exit "$CHILD"
  $ stop_daemon
