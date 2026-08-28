models download (B6) — the composition-edge responder over the runtime's
local-artifact flow. Only local providers carry a downloadable weight.

An unknown provider or model is a usage error (exit 2), uniform with the rest of
the model surface (XCUT-1).

  $ use_trusted_workspace
  $ mentat models download bogus/nope 2>&1
  mentat: unknown provider "bogus"; known providers: openai, anthropic, google, local, ollama, opencode-go
  [2]

  $ mentat models download local/not-a-model >/dev/null 2>err.txt; echo $?
  2
  $ grep -o 'unknown model "not-a-model" for provider "local"' err.txt
  unknown model "not-a-model" for provider "local"

A remote (non-local) model has no local artifact: the runtime answers
Not_downloadable, rendered as a clean runtime error (exit 1).

  $ mentat models download openai/gpt-5.6-sol 2>&1
  mentat: no local artifact for openai/gpt-5.6-sol; only local providers have downloadable weights
  [1]

In --json mode the terminal is one envelope carrying the structured outcome, and
the exit is 1 with no extra stderr.

  $ mentat models download openai/gpt-5.6-sol --json 2>/dev/null
  {"schema_version":1,"type":"model.download","outcome":{"outcome":"not_downloadable"}}
  [1]
