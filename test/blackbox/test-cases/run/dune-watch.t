The change law across one turn: the observer attaches to a (fake) dune watch
whose state a tool command flips mid-turn, and each claim-settlement drain
states exactly the difference since the last notice — a new failure, a
different error as `1 new, 1 resolved`, and a confirmed recovery — never a
repeat. The fake serves dune's own poll protocol and answers its parked
long-polls when the state file changes; the `sleep` after each flip covers
the fake's 50 ms tick so the events land before the claim settles. The quiet
window is zero because the whole exchange is local and instantaneous. No dune
or compiler is on PATH.

  $ use_trusted_workspace
  $ mentat config set dune.lint_command '[]' >/dev/null
  $ touch dune-project
  $ export MENTAT_DUNE_WATCH=observe
  $ printf failing > dune-state
  $ start_fake_dune_state "$PWD/dune-state"
  $ cat > watch.jsonl <<'JSONL'
  > {"expect":{"body_contains":["watch prompt"]},"response":{"id":"w1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-w1","call_id":"call-w1","name":"shell","arguments":"{\"command\":\"printf probed\",\"description\":\"one claim to settle\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-w1"]},"response":{"id":"w2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-w2","call_id":"call-w2","name":"shell","arguments":"{\"command\":\"printf error2 > dune-state && sleep 0.4\",\"description\":\"flip the build to a different error\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-w2"]},"response":{"id":"w3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-w3","call_id":"call-w3","name":"shell","arguments":"{\"command\":\"printf clean > dune-state && sleep 0.4\",\"description\":\"fix the build\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-w3"]},"response":{"id":"w4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"watched"}]}]}}
  > JSONL
  $ start_fake_openai watch.jsonl capture-watch port-watch
  $ MENTAT_DUNE_RPC_QUIET_S=0 mentat run "watch prompt" --cwd "$PWD" --permission bypass --id watch-turn 2>/dev/null
  watched
  $ wait_fake_server
  $ stop_fake_dune

The turn-prep request precedes the attach; it carries nothing.

  $ grep -c 'Workspace notices' capture-watch/request-1.json
  0
  [1]

The first settlement states the failure the watch held at attach.

  $ grep -c 'Build failing (1 error: 1 new)' capture-watch/request-2.json
  1
  $ grep -c 'This expression has type string' capture-watch/request-2.json
  1

A different error at the same count is a change — what appeared and what
resolved — never a silent count match. The turn's earlier observation still
reads in this request too — frozen history now, not a restatement: the
entry keeps its position and bytes, so the model replays exactly what it
saw.

  $ grep -c 'Build failing (1 error: 1 new, 1 resolved)' capture-watch/request-3.json
  1
  $ grep -c 'Unbound value restock' capture-watch/request-3.json
  1

The fix is a recovery, stated once the settle is witnessed, after the turn's
two failing observations.

  $ grep -c 'Build recovered' capture-watch/request-4.json
  1
  $ grep -o 'Build failing ([^)]*)' capture-watch/request-4.json | sort | uniq -c | sed 's/^ *//'
  1 Build failing (1 error: 1 new)
  1 Build failing (1 error: 1 new, 1 resolved)
