`models current` resolves the effective main and small models — the ones a run
would use — and explains each: it consumes the readiness query for the provider
route's credential status, and reads the config layer for where the selection
came from. The human output is a ROLE/MODEL/SOURCE/CREDENTIALS table with a
[main] row and a [small] row; [--json] is a `model.current` envelope extended
compatibly with `source`, `credentials`, and a nested `small` object. SOURCE is
[default] when selection derived the model, else the winning config source. The
small role layers over the main model: with no `small_model` configured it falls
back to the main model, so both rows show the same model under a [default]
small source.

  $ use_trusted_workspace
  $ mentat models current
  ROLE   MODEL               SOURCE   CREDENTIALS
  main   openai/gpt-5.6-sol  default  missing
  small  openai/gpt-5.6-sol  default  missing
  $ mentat models current --json
  {"schema_version":1,"type":"model.current","model":"openai/gpt-5.6-sol","source":"default","credentials":"missing","small":{"model":"openai/gpt-5.6-sol","source":"default","credentials":"missing"}}

An environment override wins over the default; SOURCE names the env variable.

  $ MENTAT_MODEL=anthropic/claude-sonnet-5 mentat models current
  ROLE   MODEL                      SOURCE            CREDENTIALS
  main   anthropic/claude-sonnet-5  env MENTAT_MODEL  missing
  small  anthropic/claude-sonnet-5  default           missing
  $ MENTAT_MODEL=openai/gpt-5.4-nano mentat models current --json
  {"schema_version":1,"type":"model.current","model":"openai/gpt-5.4-nano","source":"env MENTAT_MODEL","credentials":"missing","small":{"model":"openai/gpt-5.4-nano","source":"default","credentials":"missing"}}

A configured `small_model` is resolved independently of the main model; SOURCE
reads its own config layer, and the main row is unaffected.

  $ MENTAT_SMALL_MODEL=openai/gpt-5.4-mini mentat models current
  ROLE   MODEL                SOURCE                  CREDENTIALS
  main   openai/gpt-5.6-sol   default                 missing
  small  openai/gpt-5.4-mini  env MENTAT_SMALL_MODEL  missing

A configured selector is resolved from user config once written; SOURCE reads
[user config].

  $ mentat models select openai/gpt-5.4-mini >/dev/null
  $ mentat models current
  ROLE   MODEL                SOURCE       CREDENTIALS
  main   openai/gpt-5.4-mini  user config  missing
  small  openai/gpt-5.4-mini  default      missing

A stale or misspelled selector — from the environment or from config — is a
runtime error (exit 1), not a usage error: it names the unknown model or
provider against the known catalog.

  $ MENTAT_MODEL=openai/gpt-4 mentat models current 2>&1
  mentat: unknown model "gpt-4" for provider "openai"; known models: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5-pro, gpt-5.4-mini, gpt-5.4-nano, gpt-5.3-codex, gpt-image-2, gpt-5.3-chat-latest
  [1]
  $ MENTAT_MODEL=bogus/x mentat models current 2>&1
  mentat: unknown provider "bogus"; known providers: openai, anthropic, google, local, ollama, opencode-go
  [1]

A stale or misspelled `small_model` never blocks the run: the small role falls
back to the main model instead of erroring.

  $ MENTAT_SMALL_MODEL=openai/gpt-4 mentat models current
  ROLE   MODEL                SOURCE                  CREDENTIALS
  main   openai/gpt-5.4-mini  user config             missing
  small  openai/gpt-5.4-mini  env MENTAT_SMALL_MODEL  missing
