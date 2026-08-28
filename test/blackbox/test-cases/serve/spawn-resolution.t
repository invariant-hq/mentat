Spawn resolution: how a mentat process finds the agent binary its broker
spawns. The rest of the suite always exercises the MENTAT_BIN override
(setup.sh exports a good one), so this pins the refusal arms and the
default self-resolution the override otherwise hides. The probe is a
promptless resume of a mailed session — it must start the session's agent
before anything else, and with a bad binary nothing spawns, so no provider
is ever contacted on the refusal arms.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat session create --id sr --cwd "$PWD" >/dev/null
  $ mentat session send sr "spawn errand" --cwd "$PWD"
  delivered sr

An override naming a directory is refused loudly, before anything spawns.

  $ MENTAT_BIN="$PWD" mentat run resume sr --cwd "$PWD" 2>&1 | censor
  mentat: session sr: MENTAT_BIN names $TESTCASE_ROOT, which is not a program
  [1]

An override naming a present but non-executable file is refused the same way —
exec permission is checked here, not discovered as a child exec failure a
boot wait would time out on.

  $ touch not-a-program
  $ MENTAT_BIN="$PWD/not-a-program" mentat run resume sr --cwd "$PWD" 2>&1 | censor
  mentat: session sr: MENTAT_BIN names $TESTCASE_ROOT/not-a-program, which is not a program
  [1]

With no override, the process spawns the running executable itself — mentat
serve is a subcommand of the very binary that wants the run, so a lone
mentat with no sibling anywhere still materializes its agent. The copied
binary proves it: the agent boots, consumes the mailed turn, and the
promptless run prints its answer and exits at settlement. The response is
held briefly so the follow provably attaches while the turn runs.

  $ mkdir bins
  $ cp "$(command -v mentat)" bins/
  $ cat > script.jsonl <<'JSONL'
  > {"delay_ms":1500,"expect":{"body_contains":["spawn errand"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SELF_SPAWNED"}]}]}}
  > JSONL
  $ start_fake_openai script.jsonl
  $ MENTAT_BIN= bins/mentat run resume sr --cwd "$PWD" 2>/dev/null
  SELF_SPAWNED
  $ wait_fake_server
  $ wait_child_exit sr
