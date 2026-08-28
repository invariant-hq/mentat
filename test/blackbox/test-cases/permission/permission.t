Permission replies use one durable decision target and the session-owned answer
types. This blackbox drives real provider requests, permission reviews, tool
execution, journal replay, and feed continuation.

  $ use_trusted_workspace
  $ printf '%s\n' 'permission sentinel' > reviewed.txt

Native workspace reads are a fixed product allowance: their typed tool enforces
the workspace boundary, so `read_file` runs with no durable rule and no
permission decision. The turn completes without parking.

  $ cat > read-allowed.jsonl <<'JSONL'
  > {"expect":{"body_contains":["read allowed","\"name\":\"read_file\""]},"response":{"id":"read-allowed-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"read-allowed-item","call_id":"read-allowed-call","name":"read_file","arguments":"{\"path\":\"reviewed.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","read-allowed-call","permission sentinel"]},"response":{"id":"read-allowed-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"read complete"}]}]}}
  > JSONL
  $ start_fake_openai read-allowed.jsonl capture-read-allowed port-read-allowed
  $ mentat run start --json --cwd "$PWD" --id read-allowed "read allowed" >read-allowed.out 2>/dev/null; echo exit:$?
  exit:0
  $ grep -c '"type":"session.waiting"' read-allowed.out
  0
  [1]
  $ grep -c '"type":"decision.requested"' read-allowed.out
  0
  [1]
  $ wait_fake_server

An unconfined shell command matches no product execution credit, so it blocks
with the exact owner-encoded request. Allow-once executes that command, but an
identical later access asks again.

  $ cat > permission-first.jsonl <<'JSONL'
  > {"expect":{"body_contains":["permission first","\"name\":\"shell\""]},"response":{"id":"permission-first-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"permission-first-item","call_id":"permission-call-1","name":"shell","arguments":"{\"command\":\"cat reviewed.txt\"}"}]}}
  > JSONL
  $ start_fake_openai permission-first.jsonl capture-permission-first port-permission-first
  $ MENTAT_PERMISSION_UNATTENDED=block mentat run start --json --cwd "$PWD" --id permission-flow "permission first" >permission-first.out 2>/dev/null; echo exit:$?
  exit:3
  $ grep '"type":"session.waiting"' permission-first.out > first.waiting
  $ mentat_cram json .decision.request.type first.waiting
  permission
  $ mentat_cram json .decision.call.id first.waiting
  permission-call-1
  $ mentat_cram json .decision.request.review.reasons[0].reason.type first.waiting
  unmatched
  $ permission_first=$(mentat_cram json .decision_id first.waiting)
  $ wait_fake_server

  $ cat > permission-once.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","permission-call-1","permission sentinel"]},"response":{"id":"permission-once-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"permission-once-item","call_id":"permission-call-2","name":"shell","arguments":"{\"command\":\"cat reviewed.txt\"}"}]}}
  > JSONL
  $ start_fake_openai permission-once.jsonl capture-permission-once port-permission-once --port "$(cat port-permission-first)"
  $ mentat run reply permission-flow --json --decision "$permission_first" --allow --cwd "$PWD" >permission-once.out 2>/dev/null; echo exit:$?
  exit:3
  $ grep '"type":"session.waiting"' permission-once.out > once.waiting
  $ mentat_cram json .decision.call.id once.waiting
  permission-call-2
  $ permission_second=$(mentat_cram json .decision_id once.waiting)
  $ wait_fake_server

Allow-conversation records the exact grant. The next identical unmatched access
runs without a third decision, and the reply process follows the same feed to
the original turn's terminal outcome.

  $ cat > permission-conversation.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","permission-call-2","permission sentinel"]},"response":{"id":"permission-conversation-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"permission-conversation-item","call_id":"permission-call-3","name":"shell","arguments":"{\"command\":\"cat reviewed.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","permission-call-3","permission sentinel"]},"response":{"id":"permission-conversation-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"conversation grant continued"}]}]}}
  > JSONL
  $ start_fake_openai permission-conversation.jsonl capture-permission-conversation port-permission-conversation --port "$(cat port-permission-first)"
  $ mentat run reply permission-flow --decision "$permission_second" --allow-conversation --cwd "$PWD" 2>/dev/null
  conversation grant continued
  $ wait_fake_server
  $ find capture-permission-conversation -name 'request-*.json' | wc -l | tr -d ' '
  2

Both grants are durable in the settled journal (a parked session's agent
holds its fence mid-turn, so the export reads run after settlement).

  $ mentat session export permission-flow --format json 2>/dev/null | grep -o '"answer":"allow-once"' | head -1
  "answer":"allow-once"
  $ mentat session export permission-flow --format json 2>/dev/null | grep -o '"answer":"allow-exact-for-conversation"' | head -1
  "answer":"allow-exact-for-conversation"

Deny consumes the blocked call with the fixed model-visible error and never
exposes the command output. Custom guidance rides along with the denial without
changing that fixed error, so the reply needs the provider and is answered by a
live fake rather than rejected before the turn resumes.

  $ cat > permission-deny-first.jsonl <<'JSONL'
  > {"response":{"id":"permission-deny-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"permission-deny-item","call_id":"permission-deny-call","name":"shell","arguments":"{\"command\":\"cat reviewed.txt\"}"}]}}
  > JSONL
  $ start_fake_openai permission-deny-first.jsonl capture-permission-deny-first port-permission-deny-first
  $ mentat run start --json --cwd "$PWD" --id permission-deny "deny read" >permission-deny.out 2>/dev/null; echo exit:$?
  exit:3
  $ permission_deny=$(grep '"type":"session.waiting"' permission-deny.out | mentat_cram json .decision_id)
  $ wait_fake_server
  $ cat > permission-denied.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","permission-deny-call","The user denied permission to run this command."],"body_not_contains":["permission sentinel"]},"response":{"id":"permission-deny-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"denial continued"}]}]}}
  > JSONL
  $ start_fake_openai permission-denied.jsonl capture-permission-denied port-permission-denied --port "$(cat port-permission-deny-first)"
  $ mentat run reply permission-deny --decision "$permission_deny" --deny --message custom --cwd "$PWD" 2>/dev/null
  denial continued
  $ wait_fake_server

An explicit Review rule still wins before remembered grants. Allow-conversation
remembers the exact access, but the identical next access blocks again.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ printf '%s\n' '{"permission":{"rules":{"version":1,"items":[{"action":"review","matcher":{"type":"any"}}]}}}' > "$XDG_CONFIG_HOME/mentat/config.json"
  $ cat > permission-rule-first.jsonl <<'JSONL'
  > {"response":{"id":"permission-rule-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"permission-rule-item-1","call_id":"permission-rule-call-1","name":"shell","arguments":"{\"command\":\"cat reviewed.txt\"}"}]}}
  > JSONL
  $ start_fake_openai permission-rule-first.jsonl capture-permission-rule-first port-permission-rule-first
  $ mentat run start --json --cwd "$PWD" --id permission-rule "review rule" >permission-rule-first.out 2>/dev/null; echo exit:$?
  exit:3
  $ grep '"type":"session.waiting"' permission-rule-first.out > rule-first.waiting
  $ permission_rule=$(mentat_cram json .decision_id rule-first.waiting)
  $ mentat_cram json .decision.request.review.reasons[0].reason.type rule-first.waiting
  by-rule
  $ wait_fake_server
  $ cat > permission-rule-again.jsonl <<'JSONL'
  > {"expect":{"body_contains":["permission-rule-call-1","permission sentinel"]},"response":{"id":"permission-rule-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"permission-rule-item-2","call_id":"permission-rule-call-2","name":"shell","arguments":"{\"command\":\"cat reviewed.txt\"}"}]}}
  > JSONL
  $ start_fake_openai permission-rule-again.jsonl capture-permission-rule-again port-permission-rule-again --port "$(cat port-permission-rule-first)"
  $ mentat run reply permission-rule --json --decision "$permission_rule" --allow-conversation --cwd "$PWD" >permission-rule-again.out 2>/dev/null; echo exit:$?
  exit:3
  $ grep '"type":"session.waiting"' permission-rule-again.out | mentat_cram json .decision.call.id
  permission-rule-call-2
  $ wait_fake_server
