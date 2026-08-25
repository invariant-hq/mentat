Config rejects bad keys and values before touching a file. This is the one
home for the whole supported-keys hint block (next emits it on every unknown
key); every other config test asserts only its presence.

  $ use_trusted_workspace

An unknown key is a usage error (exit 2). The hint names the misspelling class
(none here) and then the full supported-key vocabulary on one line — pinned
whole exactly once, here.

  $ mentat config get not.a.key 2>err.txt
  [2]
  $ censor <err.txt
  mentat: unknown config key: not.a.key
  Hint: supported keys: model, small_model, reasoning, providers.<provider>.base_url, tui.thinking, tui.mouse, notify.enabled, notify.channel, notify.when, notify.command, notify.on, tui.theme, tui.theme_dark, tui.theme_light, tui.diff_layout, run.max_steps, run.subagent_max_concurrent, run.subagent_max_depth, run.subagent_max_exchanges, permission.unattended, sandbox.mode, sandbox.require, sandbox.read, sandbox.readable_roots, sandbox.writable_roots, sandbox.network, sandbox.env_inherit, sandbox.env_exclude, sandbox.env_include_only, shell, compaction.auto, revert.merge, notices.fswatch, notices.cr_comments, notices.dune_diagnostics, dune.watch, dune.targets, dune.lint_command, workspace.tooling, instructions.global, instructions.project, instructions.claude_md, instructions.project_max_bytes, skills.enabled, skills.builtin, skills.project, skills.compat, skills.disabled, skills.paths, skills.catalog_max_bytes, commands.enabled, commands.project, commands.compat, commands.disabled, tools.editor, ocaml.merlin_program, web.enabled, web.allow_private_network, web.fetch_max_bytes, web.output_max_chars, web.timeout_ms, web.max_timeout_ms, web.search_provider, web.exa_api_key, web.parallel_api_key, image.max_bytes, image.max_dimension, image.max_count

A close misspelling adds a "did you mean" line ahead of the same block; we pin
the spelling hint and assert the block is present rather than repeating it.

  $ mentat config get modle 2>err.txt
  [2]
  $ head -n 2 err.txt
  mentat: unknown config key: modle
  Hint: did you mean model?
  $ grep -c 'Hint: supported keys:' err.txt
  1

A misspelled provider key gets the provider-key shape hint, then the block.

  $ mentat config get providers.openai.baseurl 2>err.txt
  [2]
  $ head -n 2 err.txt
  mentat: unknown config key: providers.openai.baseurl
  Hint: provider keys are spelled providers.<provider>.base_url
  $ grep -c 'Hint: supported keys:' err.txt
  1

The same unknown-key gate guards set and unset, not just get.

  $ mentat config set nope value 2>err.txt; echo "exit=$?"
  exit=2
  $ head -n 1 err.txt
  mentat: unknown config key: nope

Removed surface names are also ordinary unknown keys. They have no deprecated
scalar aliases or value parsers.

  $ for key in tools.anchored_edits web.search_backend; do mentat config get "$key" 2>err.txt; printf '%s:%s\n' "$key" "$?"; head -n 1 err.txt; done
  tools.anchored_edits:2
  mentat: unknown config key: tools.anchored_edits
  web.search_backend:2
  mentat: unknown config key: web.search_backend
  $ mentat config unset nope 2>err.txt; echo "exit=$?"
  exit=2
  $ head -n 1 err.txt
  mentat: unknown config key: nope

An invalid provider id is a key error (exit 2): the id shape is checked before
any file is written.

  $ mentat config set providers.OpenAI.base_url https://example.invalid 2>&1
  mentat: invalid provider id "OpenAI": id must start with a lowercase ASCII letter
  [2]

Typed value errors are runtime errors (exit 1): the key is known, the value is
not acceptable.

  $ mentat config set reasoning hyper 2>&1
  mentat: unknown reasoning effort: hyper
  [1]

  $ mentat config set run.max_steps 0 2>&1
  mentat: run.max_steps must be positive
  [1]

  $ mentat config set run.max_steps -- -1 2>&1
  mentat: run.max_steps must be positive
  [1]

  $ mentat config set run.max_steps 1.5 2>&1
  mentat: run.max_steps must be an integer
  [1]

  $ mentat config set run.max_steps abc 2>&1
  mentat: run.max_steps must be an integer
  [1]

  $ mentat config set run.max_steps 9007199254740992 2>&1
  mentat: run.max_steps must be at most 9007199254740991
  [1]

Boolean keys accept exactly true or false.

  $ mentat config set instructions.global yes 2>&1
  mentat: instructions.global must be true or false
  [1]

  $ mentat config set instructions.claude_md TRUE 2>&1
  mentat: instructions.claude_md must be true or false
  [1]

A zero budget is invalid; disabling project instructions is spelled through
instructions.project, not through the budget.

  $ mentat config set instructions.project_max_bytes 0 2>&1
  mentat: instructions.project_max_bytes must be positive
  [1]

  $ mentat config set instructions.project_max_bytes abc 2>&1
  mentat: instructions.project_max_bytes must be an integer
  [1]

An empty model selector is a key-shape error (exit 2).

  $ mentat config set model '' 2>&1
  mentat: model selector must not be empty
  [2]

Model writes share one validation policy with `models select`: a selection
rejected there cannot be written here (exit 2).

  $ mentat config set model openai/gpt-55 2>&1
  mentat: unknown model "gpt-55" for provider "openai"; known models: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5-pro, gpt-5.4-mini, gpt-5.4-nano, gpt-5.3-codex, gpt-image-2, gpt-5.3-chat-latest
  [2]

None of the rejected edits created a config file.

  $ test -e "$XDG_CONFIG_HOME/mentat/config.json" || echo "no config"
  no config

Conflicting target flags are a command-line parse error (exit 124).

  $ mentat config set --user --project model openai/gpt-5.6-sol 2>&1
  Usage: mentat config set [--help] [OPTION]… KEY VALUE
  mentat: options --user and --project cannot be present at the same time
  [124]
