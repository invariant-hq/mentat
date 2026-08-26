The child-serve boot, blackbox through the binary: `mentat serve-session` is a
process serving exactly one delegated session — its own. Booted by hand on a
child document with no turns (the state the parent-side create leaves behind),
it re-reads the task from the durable delegation edge, mints the same
deterministic first turn the in-process backend mints, drives it to
settlement, and exits 0 once the session lingers idle — its per-session socket
directory removed. The child journal it produces is normalized-identical to
the in-process materialization, and its first-turn id is byte-identical: the
cross-backend golden any child backend must pass unchanged. A second
serve-session on the settled child is an idempotent no-op — it re-attaches,
mints nothing, and exits 0 with the journal untouched.

The sessions work in a workspace subdirectory so the fixture and capture files
this test writes are not workspace file changes the turns would drain as
notices. The linger is shortened so the two child-server exits do not pace the
test; export runs only against a stopped server because it takes the session
fence.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ trap stop_daemon EXIT
  $ export MENTAT_CHILD_LINGER=1

Poll a session's fence-free view until it is idle with the expected number of
settled turns.

  $ wait_child () {
  >   local child="$1" want="$2" tries=0 out phase turns
  >   while :; do
  >     out=$(mentat session show "$child" --json --cwd "$PWD/work" 2>/dev/null) || out=
  >     phase=$(printf '%s' "$out" | mentat_cram json .phase 2>/dev/null) || phase=
  >     turns=$(printf '%s' "$out" | mentat_cram json .turns 2>/dev/null) || turns=
  >     if [ "$phase" = idle ] && [ "$turns" = "$want" ]; then break; fi
  >     tries=$((tries + 1))
  >     if [ "$tries" -gt 300 ]; then echo "wait_child timed out: $out"; break; fi
  >     sleep 0.1
  >   done
  > }

Stage 1 — the in-process golden. The parent spawns a child inside the daemon;
the child settles its task turn; its journal is the reference the child-serve
boot must reproduce.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child works\"}"}]}}
  > {"expect":{"body_contains":["child works"],"body_not_contains":["PLEASE_SPAWN"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ start_daemon
  $ mentat run start --attach --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ wait_fake_server
  $ grep -c '"outcome":"completed"' stage1.out
  1
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ echo "$CHILD" | grep -cE '^sub-[0-9a-f]{16}$'
  1
  $ wait_child "$CHILD" 1
  $ stop_daemon
  $ mentat session export "$CHILD" --format json --cwd "$PWD/work" >child1.ndjson
  $ T1=$(sed -n '2p' child1.ndjson | mentat_cram json '.document.events[0].turn.id')
  $ echo "$T1" | grep -cE '^[0-9a-f]{20}$'
  1
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" | censor >child1.transcript
  $ cat child1.transcript
  session sub-$DIGEST1
  phase: idle
  lifecycle: active
  cwd: $TESTCASE_ROOT/work
  events: 4
  1. turn-started({ id = $DIGEST2; origin = user; input = user[1 content block(s)]; model = openai/responses:gpt-5.6-sol })
  2. provider-requested({ id = $DIGEST3; turn = $DIGEST2; request = $DIGEST4 })
  3. provider-settled(responded($DIGEST3, "CHILD_DONE"))
  4. turn-finished(turn=$DIGEST2, outcome=completed)

Stage 2 — the child-serve materialization. Reset the child to the state the
parent-side create leaves for a broker: the same document — identity,
lineage, workspace — with no events yet. The document members are rebuilt
from the settled document itself, so the reset tracks the store's own
encoding.

  $ DOC="$XDG_DATA_HOME/mentat/sessions/$CHILD/session.json"
  $ V=$(mentat_cram json .version "$DOC")
  $ M=$(mentat_cram json .metadata "$DOC")
  $ rm -rf "$XDG_DATA_HOME/mentat/sessions/$CHILD" "$XDG_DATA_HOME/mentat/sessions/$CHILD.lock"
  $ mkdir -p "$XDG_DATA_HOME/mentat/sessions/$CHILD"
  $ printf '{"version":%s,"id":"%s","metadata":%s,"events":[]}' "$V" "$CHILD" "$M" > "$DOC"

The boot serves the child from its durable edge alone: no daemon, no prompt on
argv — the task is re-read from the parent journal. It drives the first turn
to settlement, lingers idle, and exits 0 on its own.

  $ cat > stage2.jsonl <<'JSONL'
  > {"expect":{"body_contains":["child works"]},"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > JSONL
  $ start_fake_openai stage2.jsonl capture2 port2
  $ mentat serve-session --session "$CHILD" --cwd "$PWD/work" >serve1.out 2>serve1.err
  $ wait_fake_server
  $ cat serve1.err

The endpoint was derived from the session id under the daemon's denied socket
tree, stayed inside the unix-socket path budget, and was removed on the clean
exit.

  $ SOCK=$(sed -n 's/^mentat serve-session: serving .* at //p' serve1.out)
  $ echo "$SOCK" | grep -c '/s/'
  1
  $ [ "${#SOCK}" -lt 104 ] && echo within-sun-path-budget
  within-sun-path-budget
  $ test ! -e "$SOCK" && echo socket-removed
  socket-removed
  $ test ! -d "$(dirname "$SOCK")" && echo socket-dir-removed
  socket-dir-removed

The cross-backend golden: the store holds exactly one child session, under
the original id; the first-turn id is the same deterministic mint; the
normalized transcript is byte-identical to the in-process materialization.

  $ ls "$XDG_DATA_HOME/mentat/sessions/" | grep -cE '^sub-[0-9a-f]+$'
  1
  $ mentat session export "$CHILD" --format json --cwd "$PWD/work" >child2.ndjson
  $ T2=$(sed -n '2p' child2.ndjson | mentat_cram json '.document.events[0].turn.id')
  $ [ "$T1" = "$T2" ] && echo first-turn-id-identical
  first-turn-id-identical
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" | censor >child2.transcript
  $ diff child1.transcript child2.transcript && echo transcripts-identical
  transcripts-identical

Stage 3 — idempotent re-serve. A redundant spawn of a settled child
re-attaches, mints nothing, and exits 0 after the linger. The provider base
URL still names stage 2's now-dead server, so any wrongly re-issued request
would fail the turn and break the transcript diff below.

  $ mentat serve-session --session "$CHILD" --cwd "$PWD/work" >serve2.out 2>serve2.err
  $ cat serve2.err
  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" | censor >child3.transcript
  $ diff child1.transcript child3.transcript && echo idempotent-no-op
  idempotent-no-op
