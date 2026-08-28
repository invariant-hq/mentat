Background terminals end to end: a run starts a background shell command,
reads its new output, and stops it — the three short tool calls (shell with
background, shell_output, shell_kill) over one long-lived process. A
background terminal lives while its session's agent lives: the registry is
ephemeral runtime state of the driving process, so a session resumed under
a fresh agent honestly reports the prior agent's handle as gone. (The old
cross-command property — one daemon engine holding one registry across
separate runs — retired with the daemon attach.)

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"

The background start returns a handle immediately; shell_output reads it while it
runs; shell_kill stops it. The command prints a line then blocks, so the read
returns that line with a running status and the kill drains the final tail. The
[expect] guards assert the data flowed back to the model, deterministically: the
receipt handle bg_1 reaches the second request, the line and the running status
reach the third, and the line and the terminated status reach the fourth. The
read does not race the OS scheduling the child and its first write: it waits for
the write, so the line it returns is an assertion about the read rather than
about the scheduler.

  $ cat > bg.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"i1","call_id":"c1","name":"shell","arguments":"{\"command\":\"printf bg-line; sleep 30\",\"background\":true}"}]}}
  > {"expect":{"body_contains":["bg_1"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"i2","call_id":"c2","name":"shell_output","arguments":"{\"handle\":\"bg_1\"}"}]}}
  > {"expect":{"body_contains":["bg-line","running"]},"response":{"id":"r3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"i3","call_id":"c3","name":"shell_kill","arguments":"{\"handle\":\"bg_1\"}"}]}}
  > {"expect":{"body_contains":["bg-line","terminated"]},"response":{"id":"r4","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL
  $ start_fake_openai bg.jsonl capture-bg port-bg
  $ mentat run start --json --permission bypass "run a server" --cwd "$PWD" --id bg-session >bg.out 2>/dev/null
  $ wait_fake_server

The three background tools ran in order and the turn completed.

  $ grep -o '"tool":"shell"' bg.out | head -n 1
  "tool":"shell"
  $ grep -o '"tool":"shell_output"' bg.out | head -n 1
  "tool":"shell_output"
  $ grep -o '"tool":"shell_kill"' bg.out | head -n 1
  "tool":"shell_kill"
  $ grep '"type":"turn.finished"' bg.out | mentat_cram json .outcome
  completed

A background process is ephemeral runtime state: it does not survive the
session's agent. Start one in a first run, wait for that agent to idle out
(the suite's short linger), then resume the session — a fresh agent — and
poll the same handle: the registry is empty, so the poll is a structured
not-found and the model is told the process did not survive the restart.

  $ cat > start.jsonl <<'JSONL'
  > {"response":{"id":"s1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"j1","call_id":"d1","name":"shell","arguments":"{\"command\":\"printf hi; sleep 30\",\"background\":true}"}]}}
  > {"response":{"id":"s2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"started"}]}]}}
  > JSONL
  $ start_fake_openai start.jsonl capture-start port-start
  $ mentat run start --permission bypass "start a background command" --cwd "$PWD" --id resume-session >/dev/null 2>&1
  $ wait_fake_server
  $ wait_child_exit resume-session

The resumed turn polls bg_1 under a fresh agent; the not-found result
carries the restart explanation, which the [expect] guard asserts reached
the model.

  $ cat > resume.jsonl <<'JSONL'
  > {"response":{"id":"u1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"k1","call_id":"e1","name":"shell_output","arguments":"{\"handle\":\"bg_1\"}"}]}}
  > {"expect":{"body_contains":["did not survive a restart"]},"response":{"id":"u2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"gone"}]}]}}
  > JSONL
  $ start_fake_openai resume.jsonl capture-resume port-resume
  $ mentat run resume resume-session --json "poll the old handle" --cwd "$PWD" >resume.out 2>/dev/null
  $ wait_fake_server

The poll ran and returned a result (the not-found is a domain result, not a
crash), the not-found message reached the model (the [expect] guard above), and
the turn completed on the model's answer.

  $ grep '"type":"tool.finished"' resume.out | mentat_cram json .outcome
  returned
  $ grep '"type":"turn.finished"' resume.out | mentat_cram json .outcome
  completed
