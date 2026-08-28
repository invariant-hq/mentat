Ephemeral runs, beyond the flags.t basics: the throwaway store is shared
with spawned subagents (the child runs in the throwaway, never the account
store), the config home stays real (the run is trusted), and the teardown
removes the throwaway after its agents exit. TMPDIR aims the throwaway at
a local directory so the removal is observable. The leave-loudly arm (an
agent surviving the full quiesce and the escalation) needs a wedged agent
and stays untested here.

  $ use_trusted_workspace
  $ mkdir eph-tmp

A spawning ephemeral run: the parent's agent spawns a child, both settle,
and nothing — parent or child — lands in the account store.

  $ cat > eph-spawn.jsonl <<'JSONL'
  > {"expect":{"body_contains":["EPH_SPAWN"],"body_not_contains":["sp-call"]},"response":{"id":"e1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"sp-item","call_id":"sp-call","name":"spawn","arguments":"{\"task\":\"child errand\"}"}]}}
  > {"expect":{"body_contains":["child errand"],"body_not_contains":["EPH_SPAWN"]},"response":{"id":"e2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CHILD_DONE"}]}]}}
  > {"expect":{"body_contains":["EPH_SPAWN","sp-call"]},"response":{"id":"e3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"PARENT_DONE"}]}]}}
  > JSONL
  $ start_fake_openai_unordered eph-spawn.jsonl capture-spawn port-spawn
  $ TMPDIR="$PWD/eph-tmp" mentat run start --ephemeral --json --cwd "$PWD" "EPH_SPAWN" >eph-spawn.out 2>/dev/null; echo "exit:$?"
  exit:0
  $ wait_fake_server
  $ grep '"type":"run.started"' eph-spawn.out | mentat_cram json .trusted
  true
  $ grep '"type":"turn.finished"' eph-spawn.out | mentat_cram json .outcome
  completed

The child ran in the throwaway: the account store holds no sub- session
(and no session at all).

  $ ls "$XDG_DATA_HOME/mentat/sessions" 2>/dev/null | wc -l | tr -d ' '
  0

The teardown removed the throwaway after the agents exited.

  $ ls eph-tmp | wc -l | tr -d ' '
  0

A BLOCKED ephemeral run must not outlive its own store: the exit code is
the only durable fact, so the wind-down waits out the quiesce, actively
interrupts the parked agent, and removes the throwaway — no immortal
process, no leftover tree. (This stanza pays the full 15 s quiesce before
the interrupt fires.)

  $ cat > eph-park.jsonl <<'JSONL'
  > {"expect":{"body_contains":["eph park","\"name\":\"shell\""]},"response":{"id":"p1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"p-item","call_id":"p-call","name":"shell","arguments":"{\"command\":\"echo hi\"}"}]}}
  > JSONL
  $ start_fake_openai eph-park.jsonl capture-park port-park
  $ MENTAT_PERMISSION_UNATTENDED=block TMPDIR="$PWD/eph-tmp" mentat run start --ephemeral --json --cwd "$PWD" "eph park" >eph-park.out 2>/dev/null; echo "exit:$?"
  exit:3
  $ wait_fake_server
  $ grep -c '"type":"session.waiting"' eph-park.out
  1
  $ ls eph-tmp | wc -l | tr -d ' '
  0
