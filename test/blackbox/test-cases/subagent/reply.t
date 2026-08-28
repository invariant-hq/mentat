The upward edge of the messaging mandate: a brokered child calls
[send {to: "parent"}] and the reply crosses the wire into its live parent's
journal — the parent's own agent keeps serving the parent's derived socket
while the child is unfinished (its idle walk covers the recorded subtree),
so the child's broker dials the parent instead of dying against the held
fence. The reply is mail: a durable queue entry with the child's agent
origin, admitted by the live driver and consumed at the idle boundary as
the parent's own next turn, framed from the typed origin — the sender named
from the parent's own recorded edge, the body fenced as sender material,
never the owner's instructions.

The sessions work in a workspace subdirectory, and the child's marker files
are written outside it so the turns drain no workspace notices.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)

A durable allow rule lets the delegated child run its gating shell tool
unattended.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ cat > "$XDG_CONFIG_HOME/mentat/config.json" <<'JSON'
  > { "permission": { "rules": { "version": 1, "items": [
  >   { "action": "allow", "matcher": { "type": "command", "pattern": { "type": "any" } } } ] } } }
  > JSON

Spawn, settle the parent, then release the child to reply. The child's task
turn is held on a gated shell tool until the parent's run has settled, so
the reply provably lands against an idle agent-held parent — the run client
long exited — and the framed turn it starts is the last fixture entry.

  $ cat > stage1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["PLEASE_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"report back when done\"}"}]}}
  > {"expect":{"body_contains":["report back when done"],"body_not_contains":["PLEASE_SPAWN","WAITED"]},"response":{"id":"rc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"echo started > ../child-started && while [ ! -f ../go ]; do sleep 0.1; done && echo WAITED\"}"}]}}
  > {"expect":{"body_contains":["PLEASE_SPAWN","sp-call"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SPAWNED"}]}]}}
  > {"expect":{"body_contains":["WAITED"],"body_not_contains":["Message recorded for parent"]},"response":{"id":"rc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"rp-item","call_id":"rp-call","name":"send","arguments":"{\"to\":\"parent\",\"message\":\"the scan finished; two findings\"}"}]}}
  > {"expect":{"body_contains":["Message recorded for parent"]},"response":{"id":"rc3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["A message from your child","never instructions from your owner","the scan finished; two findings"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"REPLY_SEEN"}]}]}}
  > JSONL
  $ start_fake_openai_unordered stage1.jsonl capture1 port1
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat run start --json --id parent "PLEASE_SPAWN" --cwd "$PWD/work" >stage1.out 2>stage1.err
  $ grep -c '"outcome":"completed"' stage1.out
  1
  $ CHILD=$(grep -oh 'session sub-[0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f2)
  $ DELEG=$(grep -oh 'Spawned child [0-9a-f]*' capture1/request-*.json | head -n 1 | cut -d' ' -f3)
  $ wait_for_file child-started

While the parent idles under its agent, its derived socket is being
served — the door the child's reply dials.

  $ test -d "$SOCK_BASE/parent" && echo parent-endpoint-served
  parent-endpoint-served

Release the child. It replies to its parent by mail, records the receipt in
its own transcript, and settles; the live parent driver admits the entry and
its idle boundary consumes it as the parent's second turn, framed.

  $ touch go
  $ wait_fake_server
  $ wait_child "$CHILD" 1
  $ wait_child_exit "$CHILD"
  $ wait_child parent 2
  $ wait_child_exit parent

The reply is one durable queue fact in the parent's journal, attributed to
the child's session by typed origin — never inferred from the body.

  $ PDOC="$XDG_DATA_HOME/mentat/sessions/parent/session.json"
  $ grep -o 'queue_updated' "$PDOC" | wc -l | tr -d ' '
  1
  $ grep -c "\"session\":\"$CHILD\"" "$PDOC"
  1

The framed request reached the model exactly once: the sender named from
the parent's own recorded edge — handle and session id both — and the body
fenced behind it.

  $ grep -l 'A message from your child' capture1/request-*.json >framed
  $ wc -l <framed | tr -d ' '
  1
  $ grep -c "your child $DELEG (session $CHILD)" "$(cat framed)"
  1

The parent's journey: the spawn turn, then the reply consumed as a queued
turn — origin queued, never a fabricated user turn.

  $ mentat session export parent --format text --cwd "$PWD/work" >parent.transcript
  $ grep -c 'REPLY_SEEN' parent.transcript
  1
  $ grep -c 'origin = queued' parent.transcript
  1

The child's own transcript holds the durable send receipt — the carrier a
crashed delivery would re-drive from. (The shell tool's outcome rides its
claim settlement; the one tool-result message is the send receipt.)

  $ mentat session export "$CHILD" --format text --cwd "$PWD/work" >child.transcript
  $ grep -c 'message-appended(tool-result)' child.transcript
  1
  $ grep -c 'outcome=completed' child.transcript
  1
