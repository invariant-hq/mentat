Structured output: --output-schema requires the final answer to be JSON matching
the given schema. The model delivers it through a synthetic structured_output
tool the engine appends to the turn; the engine validates every call itself and
settles the turn on a conforming answer, uniformly across providers.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ cat > schema.json <<'JSON'
  > {"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}
  > JSON

A conforming structured_output call settles the turn and writes the validated
JSON to stdout verbatim with a single trailing newline; the synthetic tool rode
the request declarations.

  $ cat > happy.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"answer\":\"the final answer\"}"}]}}
  > JSONL
  $ start_fake_openai happy.jsonl capture-happy port-happy
  $ mentat run start --output-schema schema.json "produce the answer" --cwd "$PWD" --id happy >happy.out 2>/dev/null
  $ wait_fake_server
  $ cat happy.out
  {"answer":"the final answer"}
  $ mentat_cram json .answer happy.out
  the final answer
  $ grep -o '"name":"structured_output"' capture-happy/request-1.json | head -n 1
  "name":"structured_output"

With --json the lifecycle stream is unchanged, but turn.finished carries the
parsed answer as an output member and sets text to null.

  $ cat > happyjson.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"answer\":\"json answer\"}"}]}}
  > JSONL
  $ start_fake_openai happyjson.jsonl capture-happyjson port-happyjson
  $ mentat run start --json --output-schema schema.json "produce the answer" --cwd "$PWD" --id happyjson >happyjson.out 2>/dev/null
  $ wait_fake_server
  $ grep '"type":"turn.finished"' happyjson.out | mentat_cram json .output.answer
  json answer
  $ grep '"type":"turn.finished"' happyjson.out | mentat_cram json .outcome
  completed

The full tool set stays available during the run: a real tool call runs first
and only the terminating structured_output call yields the JSON answer.

  $ echo 'file body' > readme.txt
  $ cat > withtool.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"cat readme.txt\"}"}]}}
  > {"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"answer\":\"read the file\"}"}]}}
  > JSONL
  $ start_fake_openai withtool.jsonl capture-withtool port-withtool
  $ mentat run start --json --permission bypass --output-schema schema.json "use a tool then answer" --cwd "$PWD" --id withtool >withtool.out 2>/dev/null
  $ wait_fake_server
  $ grep '"type":"tool.started"' withtool.out | head -n 1 | mentat_cram json .tool
  shell
  $ grep '"type":"turn.finished"' withtool.out | mentat_cram json .output.answer
  read the file

A non-conforming call is validated by us: its violations feed back as a
model-visible error result and the run retries, recovering on a conforming
answer. The second request carries the violation text.

  $ cat > retry.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"bad-item","call_id":"bad-call","name":"structured_output","arguments":"{\"answer\":5}"}]}}
  > {"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ok-item","call_id":"ok-call","name":"structured_output","arguments":"{\"answer\":\"corrected\"}"}]}}
  > JSONL
  $ start_fake_openai retry.jsonl capture-retry port-retry
  $ mentat run start --output-schema schema.json "answer" --cwd "$PWD" --id retry >retry.out 2>/dev/null
  $ wait_fake_server
  $ mentat_cram json .answer retry.out
  corrected
  $ grep -o 'does not conform' capture-retry/request-2.json | head -n 1
  does not conform

When the model never delivers a conforming answer within the retry budget the
run fails (exit 1) with a distinct --json type, and no output member.

  $ cat > budget.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"prose one"}]}]}}
  > {"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"prose two"}]}]}}
  > {"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"prose three"}]}]}}
  > JSONL
  $ start_fake_openai budget.jsonl capture-budget port-budget
  $ mentat run start --json --output-schema schema.json "answer" --cwd "$PWD" --id budget >budget.out 2>/dev/null; echo exit:$?
  exit:1
  $ wait_fake_server
  $ grep -c '"type":"run.output_schema_failed"' budget.out
  1
  $ grep -c '"output"' budget.out
  0
  [1]

A schema file that uses an out-of-subset keyword is rejected up front (exit 2),
naming the offending keyword; the provider is never contacted.

  $ cat > uses-pattern.json <<'JSON'
  > {"type":"object","properties":{"answer":{"type":"string","pattern":"^a"}}}
  > JSON
  $ mentat run start --output-schema uses-pattern.json "answer" --cwd "$PWD" --id pattern 2>&1
  mentat: --output-schema: unsupported JSON Schema keyword "pattern" at /properties/answer
  [2]

A missing schema file, and a schema that is not a JSON object, are usage errors
(exit 2) with a clean message and no raw exception repr.

  $ mentat run start --output-schema no-such-file.json "answer" --cwd "$PWD" --id missing 2>&1
  mentat: --output-schema: file not found: no-such-file.json
  [2]
  $ printf '["not","an","object"]' > array-schema.json
  $ mentat run start --output-schema array-schema.json "answer" --cwd "$PWD" --id nonobject 2>&1
  mentat: --output-schema: the schema must be a JSON object
  [2]

resume accepts --output-schema on a new turn over an existing session.

  $ cat > resume1.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"plain first turn"}]}]}}
  > JSONL
  $ start_fake_openai resume1.jsonl capture-resume1 port-resume1
  $ mentat run start "first turn" --cwd "$PWD" --id resumed >/dev/null 2>&1
  $ wait_child_exit resumed
  $ wait_fake_server
  $ cat > resume2.jsonl <<'JSONL'
  > {"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"answer\":\"resumed answer\"}"}]}}
  > JSONL
  $ start_fake_openai resume2.jsonl capture-resume2 port-resume2
  $ mentat run resume resumed "now answer structurally" --output-schema schema.json --cwd "$PWD" >resume.out 2>/dev/null
  $ wait_fake_server
  $ mentat_cram json .answer resume.out
  resumed answer
