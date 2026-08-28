A headless turn against the fake OpenAI Responses server calls the model once
and prints the final assistant text on stdout, with the saved-session hint on
stderr. The bare `run PROMPT` form (prompt as the first token, no explicit
`start`) is spliced to `run start` by the argv rewrite.

  $ use_trusted_workspace
  $ cat > simple.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.6-sol\"","hello prompt"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello answer"}]}]}}
  > JSONL
  $ start_fake_openai simple.jsonl capture-h port-h
  $ mentat run "hello prompt" --cwd "$PWD" --id human-turn 2>stderr.txt
  hello answer
  $ cat stderr.txt
  mentat: sandbox: danger-full-access (read project, network restricted)
  mentat: session saved; resume with: mentat run resume 'human-turn'
  $ wait_fake_server

The request actually reached the fake server with the configured model and the
prompt. Because no effort was configured, turn construction also consumed the
resolved model's declared default instead of sending an absent reasoning
option.

  $ grep -o '"model":"gpt-5.6-sol"' capture-h/request-1.json
  "model":"gpt-5.6-sol"
  $ mentat_cram json .reasoning.effort capture-h/request-1.json
  medium
  $ mentat session export human-turn --format json 2>/dev/null | grep -o '"reasoning_effort":"medium"'
  "reasoning_effort":"medium"

Configured reasoning is both a model-selection requirement and a request
option. The same turn also freezes the configured response limit, which is
visible in the exported durable turn contract.

  $ cat > projected-config.jsonl <<'JSONL'
  > {"expect":{"body_contains":["projected config prompt","\"reasoning\":{\"effort\":\"high\"","\"summary\":\"auto\""]},"response":{"id":"projected-config-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"projected config answer"}]}]}}
  > JSONL
  $ start_fake_openai projected-config.jsonl capture-projected port-projected
  $ export MENTAT_REASONING=high MENTAT_MAX_STEPS=7
  $ mentat run start --cwd "$PWD" --id projected-config "projected config prompt" 2>/dev/null
  projected config answer
  $ wait_fake_server
  $ mentat_cram json .reasoning.effort capture-projected/request-1.json
  high
  $ mentat session export projected-config --format json 2>/dev/null | grep -o '"max_steps":7'
  "max_steps":7
  $ unset MENTAT_REASONING MENTAT_MAX_STEPS

An unsupported configured reasoning effort fails the selection requirement
before provider IO or session creation; it is not silently dropped from the
request.

  $ MENTAT_REASONING=minimal mentat run start --cwd "$PWD" --id unsupported-reasoning "must not run" 2>&1 | grep -o 'model does not support reasoning effort minimal (supported: none, low, medium, high, xhigh, max)'
  model does not support reasoning effort minimal (supported: none, low, medium, high, xhigh, max)
  [1]
  $ mentat session list --all --cwd "$PWD" | grep -c unsupported-reasoning || true
  0

The --json mode is a JSONL lifecycle stream: run.started (the posture),
session.started, and turn.started precede the single terminal turn.finished —
one event per line, exactly one terminal event, on stdout.

  $ cat > json.jsonl <<'JSONL'
  > {"expect":{"body_contains":["json prompt"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"json answer"}]}]}}
  > JSONL
  $ start_fake_openai json.jsonl capture-j port-j
  $ mentat run --json --cwd "$PWD" --id json-turn "json prompt" >json.out 2>/dev/null
  $ wait_fake_server
  $ grep '"type":"run.started"' json.out | mentat_cram json .sandbox.mode
  danger-full-access
  $ grep '"type":"session.started"' json.out | mentat_cram json .session_id
  json-turn
  $ grep '"type":"turn.started"' json.out | mentat_cram json .mode
  build
  $ grep '"type":"turn.started"' json.out | mentat_cram json .origin
  user
  $ grep -c '"type":"turn.finished"' json.out
  1
  $ grep '"type":"turn.finished"' json.out | mentat_cram json .text
  json answer

`--permission bypass` lets a reviewed tool run without parking, and the --json
stream surfaces the tool lifecycle: tool.started then tool.finished, correlated
by claim_id, ahead of the terminal turn.finished.

  $ echo 'file body' > readme.txt
  $ cat > toolstream.jsonl <<'JSONL'
  > {"expect":{"body_contains":["tool stream","\"name\":\"shell\""]},"response":{"id":"ts1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"ts-item","call_id":"ts-call","name":"shell","arguments":"{\"command\":\"cat readme.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","ts-call"]},"response":{"id":"ts2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"tool done"}]}]}}
  > JSONL
  $ start_fake_openai toolstream.jsonl capture-ts port-ts
  $ mentat run start --json --permission bypass --cwd "$PWD" --id toolstream "tool stream" >ts.out 2>/dev/null
  $ wait_fake_server
  $ grep '"type":"tool.started"' ts.out | mentat_cram json .tool
  shell
  $ grep '"type":"tool.started"' ts.out | mentat_cram json .call_id
  ts-call
  $ grep '"type":"tool.finished"' ts.out | mentat_cram json .outcome
  returned
  $ grep '"type":"turn.finished"' ts.out | mentat_cram json .text
  tool done

Streaming — assistant prose streams to stdout as it arrives and is reconciled
against the authoritative fact at each step boundary. Across an agentic turn the
per-step prose is newline-joined; the tool line stays on stderr, so a piped
stdout carries only the answer text, complete regardless of pipe speed.

  $ cat > multistep.jsonl <<'JSONL'
  > {"response":{"id":"ms1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"First step."}]},{"type":"function_call","id":"ms-item","call_id":"ms-call","name":"shell","arguments":"{\"command\":\"true\"}"}]}}
  > {"response":{"id":"ms2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Second step done."}]}]}}
  > JSONL
  $ start_fake_openai multistep.jsonl capture-ms port-ms
  $ mentat run start --permission bypass --cwd "$PWD" --id multistep "stream multi" >ms.out 2>ms.err
  $ wait_fake_server
  $ cat ms.out
  First step.
  Second step done.

The tool line rode stderr, never the piped answer stream.

  $ grep -c '• tool shell' ms.err
  1
  $ grep -c 'tool' ms.out
  0
  [1]

With --json the text deltas are additive events (a best-effort live hint): each
turn.text.delta carries the awaited turn's id and its chunk of prose, and the
deltas concatenate to the authoritative turn.finished.text.

  $ cat > deltas.jsonl <<'JSONL'
  > {"response":{"id":"d1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Renamed 3 occurrences."}]}]}}
  > JSONL
  $ start_fake_openai deltas.jsonl capture-d port-d
  $ mentat run --json --cwd "$PWD" --id deltas "delta prompt" >d.out 2>/dev/null
  $ wait_fake_server
  $ grep -c '"type":"turn.text.delta"' d.out
  3
  $ grep '"type":"turn.text.delta"' d.out | sed -E 's/.*"text":"([^"]*)".*/\1/' | tr -d '\n'; echo
  Renamed 3 occurrences.
  $ grep '"type":"turn.finished"' d.out | mentat_cram json .text
  Renamed 3 occurrences.

Each delta reports the awaited turn, matching turn.started.

  $ delta_turn=$(grep '"type":"turn.text.delta"' d.out | head -n 1 | sed -E 's/.*"turn_id":"([^"]*)".*/\1/')
  $ started_turn=$(grep '"type":"turn.started"' d.out | mentat_cram json .turn_id)
  $ [ "$delta_turn" = "$started_turn" ] && echo same-turn
  same-turn

Under --output-schema the deliverable is validated JSON, so no prose streams:
the model may narrate before its structured_output call, but neither the human
stdout nor the --json stream carries a text delta.

  $ cat > schema.json <<'JSON'
  > {"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}
  > JSON
  $ cat > schemastream.jsonl <<'JSONL'
  > {"response":{"id":"ss1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"prose that must not stream"}]},{"type":"function_call","id":"ss-item","call_id":"ss-call","name":"shell","arguments":"{\"command\":\"true\"}"}]}}
  > {"response":{"id":"ss2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"answer\":\"schema answer\"}"}]}}
  > JSONL
  $ start_fake_openai schemastream.jsonl capture-ss port-ss
  $ mentat run start --json --permission bypass --output-schema schema.json --cwd "$PWD" --id schemastream "schema stream" >ss.out 2>/dev/null
  $ wait_fake_server
  $ grep -c '"type":"turn.text.delta"' ss.out
  0
  [1]
  $ grep '"type":"turn.finished"' ss.out | mentat_cram json .output.answer
  schema answer

On the human path the same schema run emits only the validated JSON; the
narrated prose never leaks to stdout.

  $ start_fake_openai schemastream.jsonl capture-sh port-sh
  $ mentat run start --permission bypass --output-schema schema.json --cwd "$PWD" --id schemahuman "schema stream" >schemahuman.out 2>/dev/null
  $ wait_fake_server
  $ cat schemahuman.out
  {"answer":"schema answer"}

--thinking streams the model's reasoning summary to stderr (default off); it
never reaches stdout, so the scriptable answer stays clean.

  $ cat > thinking.jsonl <<'JSONL'
  > {"response":{"id":"th1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"pondering the request"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"final visible answer"}]}]}}
  > JSONL
  $ start_fake_openai thinking.jsonl capture-th port-th
  $ mentat run start --thinking --cwd "$PWD" --id thinking "think prompt" >th.out 2>th.err
  $ wait_fake_server
  $ cat th.out
  final visible answer
  $ grep -q 'pondering the request' th.err && echo reasoning-on-stderr
  reasoning-on-stderr

Without --thinking the reasoning summary is dropped from both streams.

  $ start_fake_openai thinking.jsonl capture-noth port-noth
  $ mentat run start --cwd "$PWD" --id nothinking "think prompt" >noth.out 2>noth.err
  $ wait_fake_server
  $ cat noth.out
  final visible answer
  $ grep -c 'pondering' noth.out
  0
  [1]
  $ grep -c 'pondering' noth.err
  0
  [1]

With --json and --thinking, reasoning surfaces as turn.reasoning.delta events on
the same turn as the text deltas.

  $ start_fake_openai thinking.jsonl capture-thj port-thj
  $ mentat run start --json --thinking --cwd "$PWD" --id thinkingjson "think prompt" >thj.out 2>/dev/null
  $ wait_fake_server
  $ grep -c '"type":"turn.reasoning.delta"' thj.out
  3
  $ grep '"type":"turn.reasoning.delta"' thj.out | sed -E 's/.*"text":"([^"]*)".*/\1/' | tr -d '\n'; echo
  pondering the request

An unattended permission review follows the configured permission-domain
posture. `block` leaves the session waiting for `run reply`; `deny` records the
engine-owned unattended denial and continues the same live feed through the
tool result and terminal turn, without executing the reviewed command.

  $ echo 'must not be read' > unattended-input.txt
  $ cat > unattended-block.jsonl <<'JSONL'
  > {"expect":{"body_contains":["block unattended","\"name\":\"shell\""]},"response":{"id":"unattended-block-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"unattended-block-item","call_id":"unattended-block-call","name":"shell","arguments":"{\"command\":\"cat unattended-input.txt\"}"}]}}
  > JSONL
  $ start_fake_openai unattended-block.jsonl capture-unattended-block port-unattended-block
  $ MENTAT_PERMISSION_UNATTENDED=block mentat run --json --cwd "$PWD" --id unattended-block "block unattended" >unattended-block.out 2>/dev/null; echo exit:$?
  exit:3
  $ grep -c '"type":"session.waiting"' unattended-block.out
  1
  $ grep '"type":"session.waiting"' unattended-block.out | mentat_cram json .type
  session.waiting
  $ wait_fake_server

  $ cat > unattended-deny.jsonl <<'JSONL'
  > {"expect":{"body_contains":["deny unattended","\"name\":\"shell\""]},"response":{"id":"unattended-deny-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"unattended-deny-item","call_id":"unattended-deny-call","name":"shell","arguments":"{\"command\":\"cat unattended-input.txt\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","unattended-deny-call"],"body_not_contains":["must not be read"]},"response":{"id":"unattended-deny-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"unattended denial continued"}]}]}}
  > JSONL
  $ start_fake_openai unattended-deny.jsonl capture-unattended-deny port-unattended-deny
  $ MENTAT_PERMISSION_UNATTENDED=deny mentat run --json --cwd "$PWD" --id unattended-deny "deny unattended" >unattended-deny.out 2>/dev/null
  $ wait_fake_server
  $ grep '"type":"turn.finished"' unattended-deny.out | mentat_cram json .text
  unattended denial continued

The denial continues the same feed: the stream pairs a decision.requested with
the engine's decision.resolved, never a terminal session.waiting.

  $ grep -c '"type":"session.waiting"' unattended-deny.out
  0
  [1]
  $ grep '"type":"decision.requested"' unattended-deny.out | mentat_cram json .decision.call.name
  shell
  $ grep '"type":"decision.resolved"' unattended-deny.out | mentat_cram json .resolution.answered_by
  unattended_policy
  $ mentat session export unattended-deny --format json 2>/dev/null | grep -o '"answered_by":"unattended_policy"'
  "answered_by":"unattended_policy"

`deny` is deliberately not a generic decision auto-responder. A reviewer
question still blocks, proving that the unattended principal is used only for
permission denials.

  $ cat > unattended-question.jsonl <<'JSONL'
  > {"expect":{"body_contains":["question unattended","\"name\":\"ask_user\""]},"response":{"id":"unattended-question-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"unattended-question-item","call_id":"unattended-question-call","name":"ask_user","arguments":"{\"prompt\":\"Which deployment target?\"}"}]}}
  > JSONL
  $ start_fake_openai unattended-question.jsonl capture-unattended-question port-unattended-question
  $ MENTAT_PERMISSION_UNATTENDED=deny mentat run --json --cwd "$PWD" --id unattended-question "question unattended" >unattended-question.out 2>/dev/null; echo exit:$?
  exit:3
  $ grep '"type":"session.waiting"' unattended-question.out > waiting.out
  $ mentat_cram json .type waiting.out
  session.waiting
  $ mentat_cram json .decision.request.type waiting.out
  question
  $ mentat_cram json .decision.call.id waiting.out
  unattended-question-call
  $ mentat_cram json .decision.stage waiting.out
  direct
  $ mentat_cram json .decision.request.prompt.prompt waiting.out
  Which deployment target?
  $ question_decision=$(mentat_cram json .decision_id waiting.out)
  $ wait_fake_server

The copied decision id prevents a stale command from answering whichever
request happens to be pending. A wrong id leaves the question pending; the
exact id accepts trimmed free text, and the provider sees that typed answer as
the original tool result before the turn completes.

  $ mentat run reply unattended-question --decision stale-decision --answer staging --cwd "$PWD" 2>&1 | censor
  mentat: pending decision is $DIGEST, not stale-decision
  [2]
  $ cat > unattended-question-answer.jsonl <<'JSONL'
  > {"expect":{"body_contains":["function_call_output","unattended-question-call","staging"]},"response":{"id":"unattended-question-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"question answer continued"}]}]}}
  > JSONL
  $ start_fake_openai unattended-question-answer.jsonl capture-unattended-question-answer port-unattended-question-answer --port "$(cat port-unattended-question)"
  $ mentat run reply unattended-question --decision "$question_decision" --answer '  staging  ' --cwd "$PWD" 2>/dev/null
  question answer continued
  $ wait_fake_server

Human waiting output carries the same owner payload and a valid command with
the exact durable target. It does not recommend the invalid no-prompt resume
form.

  $ cat > human-question.jsonl <<'JSONL'
  > {"expect":{"body_contains":["human question","\"name\":\"ask_user\""]},"response":{"id":"human-question-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"human-question-item","call_id":"human-question-call","name":"ask_user","arguments":"{\"prompt\":\"Choose a region\",\"choices\":[\"eu-west\",\"us-east\"]}"}]}}
  > JSONL
  $ start_fake_openai human-question.jsonl capture-human-question port-human-question
  $ mentat run start --cwd "$PWD" --id human-question "human question" >human-question.out 2>&1; echo exit:$?
  exit:3
  $ grep -E '^(Decision |Tool call |Question: |  [12]\. |Reply with:|  mentat run reply )' human-question.out | censor
  Decision $DIGEST (question)
  Tool call human-question-call: ask_user (direct)
  Question: Choose a region
    1. eu-west
    2. us-east
  Reply with:
    mentat run reply 'human-question' --decision '$DIGEST' --answer 'YOUR ANSWER'
  $ grep -c 'session saved; resume with' human-question.out || true
  0
  $ wait_fake_server

The turn persisted an idle session that is listed and resumable.

  $ mentat session show json-turn --cwd "$PWD" | grep -E '^(id|phase|lifecycle)='
  id=json-turn
  phase=idle
  lifecycle=active

F4 / RUN-10 — the resume arg-model is a SESSION_OR_PROMPT matrix: a bare
resume without a target is a structured usage error (exit 2), never
cmdliner's 124, and extra positionals under --last refuse. (A no-prompt
resume with a target is the supported promptless form — run/inbox.t.)

  $ mentat run resume --cwd "$PWD" 2>&1
  mentat: resume requires SESSION or --last
  [2]
  $ mentat run resume --last "p" extra --cwd "$PWD" 2>&1
  mentat: with --last, pass only a PROMPT
  [2]

RUN-09 — a run that cannot authenticate is gated before it creates a session, so
it never litters an empty idle session, and the message carries a login hint.

  $ unset OPENAI_API_KEY MENTAT_MODEL MENTAT_OPENAI_BASE_URL
  $ mentat run start --id litter "hi" --cwd "$PWD" 2>&1
  mentat: sandbox: danger-full-access (read project, network restricted)
  mentat: no credential for provider openai; run `mentat auth login openai`
  [1]
  $ mentat session list --all --cwd "$PWD" | grep -c litter || true
  0

RUN-03 — `run -- PROMPT` escapes a prompt colliding with a subcommand name: the
bare `run -- start` splices to `run start -- start` and reaches the turn (here
gated on credentials), instead of cmdliner's "unknown command" / "too many
arguments" (POSIX: any flags must precede `-- PROMPT`).

  $ mentat run -- start 2>&1
  mentat: sandbox: danger-full-access (read project, network restricted)
  mentat: no credential for provider openai; run `mentat auth login openai`
  [1]

F3 / RUN-11 — `--cwd` on resume is an assertion: a session resumed from a workspace
other than its recorded cwd refuses (exit 2) before running anywhere.

  $ mentat session create --id cwdc --cwd "$PWD" >/dev/null
  $ mkdir -p sub
  $ mentat run resume cwdc "again" --cwd "$PWD/sub" 2>&1
  mentat: session cwdc was recorded in $TESTCASE_ROOT, not $TESTCASE_ROOT/sub; resume from its workspace
  [2]

`run reply` validates the durable target, the one-of action matrix, and free
text before any client is built. The required decision id is a semantic usage
error (2), while retired flags are absent from the parser (124).

  $ mentat session create --id blocked --cwd "$PWD" >/dev/null
  $ mentat run reply blocked --cwd "$PWD" 2>&1
  mentat: reply requires --decision DECISION_ID
  [2]
  $ mentat run reply blocked --decision '   ' --allow --cwd "$PWD" 2>&1
  mentat: --decision must not be empty
  [2]
  $ mentat run reply blocked --decision d --allow --deny --cwd "$PWD" 2>&1
  mentat: choose exactly one of --allow, --allow-conversation, --deny, --approve-plan, --reject-plan, or --answer
  [2]
  $ mentat run reply blocked --decision d --answer '   ' --cwd "$PWD" 2>&1
  mentat: --answer must not be empty
  [2]
  $ mentat run reply blocked --decision d --approve-plan --message '   ' --cwd "$PWD" 2>&1
  mentat: --message must not be empty
  [2]
  $ mentat run reply blocked --decision d --deny --message no --cwd "$PWD" 2>&1
  mentat: no pending decision on blocked
  [2]
  $ mentat run reply blocked --decision d --message orphan --cwd "$PWD" 2>&1
  mentat: --message requires --deny, --approve-plan, or --reject-plan
  [2]
  $ mentat run reply blocked --decision d --question old-call --answer yes --cwd "$PWD" >/dev/null 2>&1; echo exit:$?
  exit:124
  $ mentat run reply blocked --decision d --tool-interrupted old --cwd "$PWD" >/dev/null 2>&1; echo exit:$?
  exit:124
  $ mentat run reply blocked --decision d --reason old --cwd "$PWD" >/dev/null 2>&1; echo exit:$?
  exit:124

A well-formed action reaches the pending-decision query. This pre-created
session has no pending decision to answer.

  $ mentat run reply blocked --decision d --allow --cwd "$PWD" 2>&1
  mentat: no pending decision on blocked
  [2]

`run reply --title` renames the session — a distinct reply mode that takes no
pending decision and starts no turn.

  $ mentat run reply blocked --title "Renamed" --cwd "$PWD" 2>/dev/null
  $ mentat session show blocked --cwd "$PWD" | grep -E '^title='
  title=Renamed

A decision answer and a title action cannot be combined.

  $ mentat run reply blocked --decision d --allow --title "x" --cwd "$PWD" 2>&1
  mentat: choose one of a decision answer or --title
  [2]
