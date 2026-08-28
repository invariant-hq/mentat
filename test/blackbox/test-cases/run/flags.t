Restored `run start` flags overlay the resolved configuration the executable
seals the turn contract from, or (for `--mode`) travel on the prompt command.
Each is observable in the durable turn contract, the request the fake server
records, or the run-start posture, without needing a live model.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"

`--max-steps` freezes the turn's step limit; the durable contract records it.

  $ cat > steps.jsonl <<'JSONL'
  > {"expect":{"body_contains":["steps prompt"]},"response":{"id":"s1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}
  > JSONL
  $ start_fake_openai steps.jsonl capture-steps port-steps
  $ mentat run start --max-steps 3 --cwd "$PWD" --id steps "steps prompt" 2>/dev/null
  ok
  $ wait_fake_server
  $ wait_child_exit steps
  $ mentat session export steps --format json 2>/dev/null | grep -o '"max_steps":3'
  "max_steps":3

A non-positive `--max-steps` is a structured usage error before any run.

  $ mentat run start --max-steps 0 --cwd "$PWD" --id bad-steps "x" 2>&1
  mentat: --max-steps must be positive, got 0
  [2]

`--reasoning` as a flag is the same override the MENTAT_REASONING environment
drives: it is both a selection requirement and a request option.

  $ cat > reason.jsonl <<'JSONL'
  > {"expect":{"body_contains":["reason prompt","\"reasoning\":{\"effort\":\"high\""]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}
  > JSONL
  $ start_fake_openai reason.jsonl capture-reason port-reason
  $ mentat run start --reasoning high --cwd "$PWD" --id reason "reason prompt" 2>/dev/null
  ok
  $ wait_fake_server
  $ mentat_cram json .reasoning.effort capture-reason/request-1.json
  high

An unsupported `--reasoning` fails the selection requirement before any IO.

  $ mentat run start --reasoning minimal --cwd "$PWD" --id bad-reason "x" 2>&1 | grep -o 'model does not support reasoning effort minimal'
  model does not support reasoning effort minimal
  [1]

`--title` names the new session; the saved session carries it.

  $ cat > title.jsonl <<'JSONL'
  > {"expect":{"body_contains":["title prompt"]},"response":{"id":"t1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}
  > JSONL
  $ start_fake_openai title.jsonl capture-title port-title
  $ mentat run start --title "My Session" --cwd "$PWD" --id titled "title prompt" 2>/dev/null
  ok
  $ wait_fake_server
  $ mentat session show titled --cwd "$PWD" | grep -E '^title='
  title=My Session

`--sandbox` overlays the configured posture; the run-start posture block on
stderr announces it.

  $ cat > box.jsonl <<'JSONL'
  > {"expect":{"body_contains":["box prompt"]},"response":{"id":"b1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}
  > JSONL
  $ start_fake_openai box.jsonl capture-box port-box
  $ mentat run start --sandbox read-only --cwd "$PWD" --id boxed "box prompt" 2>posture.txt >/dev/null
  $ wait_fake_server
  $ grep -o 'sandbox: read-only' posture.txt
  sandbox: read-only

An unknown `--mode` is a structured usage error.

  $ mentat run start --mode fly --cwd "$PWD" --id bad-mode "x" 2>&1
  mentat: unknown mode "fly"; expected build, plan, or review
  [2]

`--no-skills` disables skill discovery: the request carries no skills catalog.

  $ mkdir -p .mentat/skills/greeter
  $ cat > .mentat/skills/greeter/SKILL.md <<'MD'
  > ---
  > name: greeter
  > description: Greet warmly.
  > ---
  > Always greet the user warmly before answering.
  > MD
  $ cat > noskills.jsonl <<'JSONL'
  > {"expect":{"body_contains":["noskills prompt"]},"response":{"id":"n1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}
  > JSONL
  $ start_fake_openai noskills.jsonl capture-noskills port-noskills
  $ mentat run start --no-skills --cwd "$PWD" --id noskills "noskills prompt" 2>/dev/null
  ok
  $ wait_fake_server
  $ grep -c 'Available skills:' capture-noskills/request-1.json
  0
  [1]

`--skill NAME` pins that skill's guidance as user content ahead of the prompt,
so the request carries its body verbatim.

  $ cat > skill.jsonl <<'JSONL'
  > {"expect":{"body_contains":["skill prompt","Always greet the user warmly"]},"response":{"id":"k1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}}
  > JSONL
  $ start_fake_openai skill.jsonl capture-skill port-skill
  $ mentat run start --skill greeter --cwd "$PWD" --id skilled "skill prompt" 2>/dev/null
  ok
  $ wait_fake_server
  $ grep -o 'Always greet the user warmly before answering' capture-skill/request-1.json
  Always greet the user warmly before answering

An unknown `--skill` name is a usage error before the run.

  $ mentat run start --skill nope --cwd "$PWD" --id bad-skill "x" 2>&1 | grep -o 'nope' | head -1
  nope
  [2]

`--ephemeral` runs the turn under a throwaway store, so nothing is persisted to
the account session store.

  $ cat > eph.jsonl <<'JSONL'
  > {"expect":{"body_contains":["ephemeral prompt"]},"response":{"id":"e1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ephemeral answer"}]}]}}
  > JSONL
  $ start_fake_openai eph.jsonl capture-eph port-eph
  $ mentat run start --ephemeral --cwd "$PWD" "ephemeral prompt" 2>/dev/null
  ephemeral answer
  $ wait_fake_server
  $ mentat session list --all --cwd "$PWD" | grep -c 'ephemeral prompt' || true
  0

`--ephemeral` cannot be combined with `--id`, whose only purpose is a later
resume the throwaway store makes impossible.

  $ mentat run start --ephemeral --id keep-me --cwd "$PWD" "x" 2>&1
  mentat: --ephemeral discards the session; it cannot be combined with --id
  [2]
