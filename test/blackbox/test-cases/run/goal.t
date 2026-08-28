The goal loop (RFC 0027): `mentat run --goal OBJECTIVE` records standing
intent on a fresh session, then continues it at each finished judgment —
a framed continuation turn sealed under the goal_status schema — until
the model declares the goal done, a recorded bound stops the loop, or the
owner does. The engine never learns the word goal: the schema rides the
generic output-schema channel, and an absent claim means continue.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"

The flag grammar refuses up front, before any run: the objective is the
prompt, and the bounds require the goal.

  $ mentat run --goal "x" "and a prompt" --cwd "$PWD" 2>&1
  mentat: --goal cannot be combined with PROMPT (the objective is the prompt)
  [2]
  $ mentat run --max-turns 2 "p" --cwd "$PWD" 2>&1
  mentat: --max-turns and --budget require --goal
  [2]
  $ mentat run --goal "  " --cwd "$PWD" 2>&1
  mentat: --goal must not be empty
  [2]
  $ mentat run --goal "x" --max-turns 0 --cwd "$PWD" 2>&1
  mentat: --max-turns must be positive, got 0
  [2]

Two continuations, then done: the first claim declares continuing, the
second declares done. Every request carries the framed continuation text,
the goal_status instruction, and the sealed structured_output tool; the
loop narrates each turn on stderr and exits 0 at the declaration.

  $ cat > goal.jsonl <<'JSONL'
  > {"expect":{"body_contains":["Continuing toward the goal: make the fixture green","goal_status","\"name\":\"structured_output\""]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"g1-item","call_id":"g1-call","name":"structured_output","arguments":"{\"status\":\"continuing\",\"note\":\"halfway\"}"}]}}
  > {"expect":{"body_contains":["Continuing toward the goal: make the fixture green"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"g2-item","call_id":"g2-call","name":"structured_output","arguments":"{\"status\":\"done\",\"note\":\"all green\"}"}]}}
  > JSONL
  $ start_fake_openai goal.jsonl
  $ mentat run --goal "make the fixture green" --max-turns 5 --id goal1 --cwd "$PWD" >goal1.out 2>goal1.err; echo "exit:$?"
  exit:0
  $ wait_fake_server
  $ wait_child_exit goal1
  $ grep -c 'continuing toward the goal' goal1.err
  2
  $ grep 'turn 1 of 5' goal1.err
  mentat: continuing toward the goal (turn 1 of 5)
  $ grep 'goal declared done' goal1.err
  mentat: goal declared done: all green
  $ test -s goal1.out || echo no-stdout
  no-stdout

The intent and both framed turns are durable in the session document.

  $ DOC="$XDG_DATA_HOME/mentat/sessions/goal1/session.json"
  $ grep -o '"objective":"make the fixture green"' "$DOC"
  "objective":"make the fixture green"
  $ grep -o 'turn_started' "$DOC" | wc -l | tr -d ' '
  2

Re-arming a goal whose head already declared done settles immediately —
no agent starts, no provider is contacted (the fixture is down), and the
recorded intent still names the goal.

  $ mentat run resume goal1 --cwd "$PWD" 2>resume1.err; echo "exit:$?"
  exit:0
  $ grep 're-arming the goal' resume1.err
  mentat: re-arming the goal: make the fixture green
  $ grep 'goal declared done' resume1.err
  mentat: goal declared done: all green

The turn bound: --max-turns 1 stops the loop after one continuing claim,
with the honest nonzero and the re-arm hint.

  $ cat > bound.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"b1-item","call_id":"b1-call","name":"structured_output","arguments":"{\"status\":\"continuing\",\"note\":\"one down\"}"}]}}
  > JSONL
  $ start_fake_openai bound.jsonl capture-bound port-bound
  $ mentat run --goal "count to ten" --max-turns 1 --id goal2 --cwd "$PWD" 2>goal2.err; echo "exit:$?"
  exit:1
  $ wait_fake_server
  $ wait_child_exit goal2
  $ grep 'turn bound' goal2.err
  mentat: the goal's turn bound (1) is spent without a done declaration; raise --max-turns and re-arm with `mentat run resume 'goal2'`

Re-recording the same objective with a higher bound continues the same
ledger: the journal already holds one framed turn, so the next
continuation is turn 2 — and the counter proves derived, never persisted.

  $ cat > bound2.jsonl <<'JSONL'
  > {"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"b2-item","call_id":"b2-call","name":"structured_output","arguments":"{\"status\":\"done\"}"}]}}
  > JSONL
  $ start_fake_openai bound2.jsonl capture-bound2 port-bound2
  $ mentat run resume goal2 --goal "count to ten" --max-turns 3 --cwd "$PWD" 2>goal2b.err; echo "exit:$?"
  exit:0
  $ wait_fake_server
  $ wait_child_exit goal2
  $ grep 'turn 2 of 3' goal2b.err
  mentat: continuing toward the goal (turn 2 of 3)
  $ grep 'goal declared done' goal2b.err
  mentat: goal declared done

The budget: the journal's whole cost fold, read at the continuation
decision — a continuing claim whose turn spent past the bound stops the
loop with the honest nonzero.

  $ cat > budget.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","usage":{"input_tokens":100000,"output_tokens":1000},"output":[{"type":"function_call","id":"u1-item","call_id":"u1-call","name":"structured_output","arguments":"{\"status\":\"continuing\",\"note\":\"expensive\"}"}]}}
  > JSONL
  $ start_fake_openai budget.jsonl capture-budget port-budget
  $ mentat run --goal "spend carefully" --budget 0.05 --id goal3 --cwd "$PWD" 2>goal3.err; echo "exit:$?"
  exit:1
  $ wait_fake_server
  $ wait_child_exit goal3
  $ grep 'budget' goal3.err
  mentat: the goal's budget ($0.05) is spent without a done declaration; raise --budget and re-arm with `mentat run resume 'goal3'`

A goal recorded on a session that is already finished with no claim: the
head turn completed as plain prose, so the loop's first decision is
continue — the fresh objective runs and the declaration ends it.

  $ cat > plain.jsonl <<'JSONL'
  > {"expect":{"body_contains":["write the intro"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"INTRO DONE"}]}]}}
  > {"expect":{"body_contains":["Continuing toward the goal: polish the intro"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"p2-item","call_id":"p2-call","name":"structured_output","arguments":"{\"status\":\"done\",\"note\":\"polished\"}"}]}}
  > JSONL
  $ start_fake_openai plain.jsonl capture-plain port-plain
  $ mentat run start --id plain "write the intro" --cwd "$PWD" 2>/dev/null
  INTRO DONE
  $ wait_child_exit plain
  $ mentat run resume plain --goal "polish the intro" --cwd "$PWD" >plain2.out 2>plain2.err; echo "exit:$?"
  exit:0
  $ wait_fake_server
  $ wait_child_exit plain
  $ grep 'goal declared done' plain2.err
  mentat: goal declared done: polished
