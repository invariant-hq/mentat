The next-turn model is resolved by a fixed precedence — process-local overlay >
session latest_model > config default (bin/composition.ml config_callback). The
overlay is a live, process-only preference the TUI model picker sets through the
client; headless `run` has no flag that reaches it (`--model` and MENTAT_MODEL
both feed the config default, the lowest tier). So the middle tier — a resumed
session continuing on the model its own journal last recorded, rather than the
global config default — is the one a unit test cannot reach and the one this
fixture pins end to end. It closes a real defect where a resumed session
silently reverted to the config default.

Because headless has no per-session overlay flag, the only way to separate
latest_model from the config default is to run the recording turn under one
config default and resume under a different one: turn 1 records gpt-5.4-mini into the
journal, the config default is then flipped to gpt-5.6-sol, and the resume must still
request gpt-5.4-mini. The model a run actually requests is visible in the provider
capture as the request body's "model" member.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"

Turn 1 runs session `precedence` with the config default set to gpt-5.4-mini, so its
contract model — the durable fact the engine replays as latest_model — is
gpt-5.4-mini. The capture confirms the request carried that model.

  $ cat > turn1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.4-mini\"","first prompt"]},"response":{"id":"precedence-1","status":"completed","model":"gpt-5.4-mini","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > JSONL
  $ start_fake_openai turn1.jsonl capture-turn1 port-turn1
  $ export MENTAT_MODEL=openai/gpt-5.4-mini
  $ mentat run start --id precedence "first prompt" --cwd "$PWD" 2>/dev/null
  first answer
  $ wait_fake_server
  $ grep -o '"model":"gpt-5.4-mini"' capture-turn1/request-1.json
  "model":"gpt-5.4-mini"

Now flip the config default to gpt-5.6-sol. A brand-new session has no journal to
replay, so its next turn falls to the config default: session `fresh` requests
gpt-5.6-sol. This is the baseline that proves gpt-5.6-sol is genuinely the ambient config
default from here on — so the resume below requesting gpt-5.4-mini can only be the
session's own memory, not a stale default.

  $ export MENTAT_MODEL=openai/gpt-5.6-sol
  $ cat > fresh.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.6-sol\"","fresh prompt"]},"response":{"id":"fresh-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fresh answer"}]}]}}
  > JSONL
  $ start_fake_openai fresh.jsonl capture-fresh port-fresh
  $ mentat run start --id fresh "fresh prompt" --cwd "$PWD" 2>/dev/null
  fresh answer
  $ wait_fake_server
  $ grep -o '"model":"gpt-5.6-sol"' capture-fresh/request-1.json
  "model":"gpt-5.6-sol"

Resuming `precedence` with the config default now gpt-5.6-sol, the next turn must
continue on the model the session last ran — gpt-5.4-mini, replayed from its journal
as latest_model — and beat the config default. The fixture's body_not_contains
makes it a hard gate: were the resumed turn to revert to the config default
(the fixed defect), the request would carry gpt-5.6-sol and the fake server would
reject it.

  $ cat > resume.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"gpt-5.4-mini\"","resumed prompt"],"body_not_contains":["\"model\":\"gpt-5.6-sol\""]},"response":{"id":"precedence-2","status":"completed","model":"gpt-5.4-mini","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"resumed answer"}]}]}}
  > JSONL
  $ start_fake_openai resume.jsonl capture-resume port-resume
  $ wait_child_exit precedence
  $ mentat run resume precedence "resumed prompt" --cwd "$PWD" 2>/dev/null
  resumed answer
  $ wait_fake_server
  $ grep -o '"model":"gpt-5.4-mini"' capture-resume/request-1.json
  "model":"gpt-5.4-mini"
  $ grep -c '"model":"gpt-5.6-sol"' capture-resume/request-1.json || true
  0
