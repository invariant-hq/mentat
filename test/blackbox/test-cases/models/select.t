`models select` writes the canonical selector into user config through the same
edit path `config get` reads. next's select always targets user config (there
is no --project/--user split); a rejected selection mutates nothing.

An unknown model or provider is a usage error (exit 2) and creates no config
file.

  $ use_trusted_workspace
  $ mentat models select openai/no-such-model 2>&1
  mentat: unknown model "no-such-model" for provider "openai"; known models: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5-pro, gpt-5.4-mini, gpt-5.4-nano, gpt-5.3-codex, gpt-image-2, gpt-5.3-chat-latest
  [2]
  $ test -e config/mentat/config.json || echo "no config"
  no config

Selecting a main model writes the `model` key and echoes the written pair.

  $ mentat models select openai/gpt-5.6-sol
  model openai/gpt-5.6-sol
  $ mentat config get model
  openai/gpt-5.6-sol
  $ cat config/mentat/config.json
  {"model":"openai/gpt-5.6-sol"}

The `--small` flag targets the auxiliary `small_model` key instead of `model`.
It shares the one write path, echoes the written pair keyed by `small_model`,
and leaves the main model untouched.

  $ mentat models select --small openai/gpt-5.4-mini
  small_model openai/gpt-5.4-mini
  $ mentat config get small_model
  openai/gpt-5.4-mini
  $ mentat config get model
  openai/gpt-5.6-sol
  $ cat config/mentat/config.json
  {"model":"openai/gpt-5.6-sol","small_model":"openai/gpt-5.4-mini"}

An unknown small selector is the same usage error (exit 2) and writes nothing.

  $ mentat models select --small openai/no-such-model 2>&1
  mentat: unknown model "no-such-model" for provider "openai"; known models: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5-pro, gpt-5.4-mini, gpt-5.4-nano, gpt-5.3-codex, gpt-image-2, gpt-5.3-chat-latest
  [2]
  $ mentat config get small_model
  openai/gpt-5.4-mini

A rejected selection does not modify an existing config file either.

  $ mentat models select nosuch/model-x 2>&1
  mentat: unknown provider "nosuch"; known providers: openai, anthropic, google, local, ollama, opencode-go
  [2]
  $ cat config/mentat/config.json
  {"model":"openai/gpt-5.6-sol","small_model":"openai/gpt-5.4-mini"}
