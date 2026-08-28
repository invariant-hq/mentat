Config show renders the effective configuration three ways: sorted key=value
text, an enveloped JSON map, and an origin-annotated view. The shell default is
host-derived, so SHELL is unset to pin the /bin/sh fallback.

  $ use_trusted_workspace
  $ unset SHELL

The text view is one sorted key=value per line, every key present including
built-in defaults.

  $ mentat config show | censor
  commands.compat=true
  commands.disabled=[]
  commands.enabled=true
  commands.project=true
  compaction.auto=true
  dune.lint_command=["litany","check","--no-build","--trust-build"]
  dune.targets=["@check"]
  dune.watch=auto
  image.max_bytes=5242880
  image.max_count=20
  image.max_dimension=8000
  instructions.claude_md=true
  instructions.global=true
  instructions.project=true
  instructions.project_max_bytes=32768
  notices.cr_comments=true
  notices.dune_diagnostics=true
  notices.fswatch=true
  notify.channel=auto
  notify.command=[]
  notify.enabled=true
  notify.on=["turn-done","decision"]
  notify.when=unfocused
  ocaml.merlin_program=["ocamlmerlin"]
  permission.unattended=block
  revert.merge=true
  run.subagent_max_concurrent=4
  run.subagent_max_depth=2
  run.subagent_max_exchanges=8
  sandbox.env_exclude=[]
  sandbox.env_include_only=[]
  sandbox.env_inherit=allowlist
  sandbox.mode=danger-full-access
  sandbox.network=restricted
  sandbox.read=project
  sandbox.readable_roots=[]
  sandbox.require=enforced
  sandbox.writable_roots=[]
  shell=/bin/sh
  skills.builtin=true
  skills.catalog_max_bytes=8192
  skills.compat=true
  skills.disabled=[]
  skills.enabled=true
  skills.paths=[]
  skills.project=true
  tools.editor=auto
  tui.diff_layout=auto
  tui.mouse=true
  tui.theme=mentat-dark
  tui.theme_dark=mentat-dark
  tui.theme_light=mentat-light
  tui.thinking=true
  web.allow_private_network=false
  web.enabled=false
  web.fetch_max_bytes=5242880
  web.max_timeout_ms=120000
  web.output_max_chars=100000
  web.search_provider=exa
  web.timeout_ms=30000
  workspace.tooling=auto
  workspace_trust=trusted

The JSON view is a single enveloped object: schema_version, type, workspace
trust, and a string-valued values map.

  $ mentat config show --json | censor
  {"schema_version":1,"type":"config","workspace_trust":"trusted","values":{"commands.compat":"true","commands.disabled":"[]","commands.enabled":"true","commands.project":"true","compaction.auto":"true","dune.lint_command":"[\"litany\",\"check\",\"--no-build\",\"--trust-build\"]","dune.targets":"[\"@check\"]","dune.watch":"auto","image.max_bytes":"5242880","image.max_count":"20","image.max_dimension":"8000","instructions.claude_md":"true","instructions.global":"true","instructions.project":"true","instructions.project_max_bytes":"32768","notices.cr_comments":"true","notices.dune_diagnostics":"true","notices.fswatch":"true","notify.channel":"auto","notify.command":"[]","notify.enabled":"true","notify.on":"[\"turn-done\",\"decision\"]","notify.when":"unfocused","ocaml.merlin_program":"[\"ocamlmerlin\"]","permission.unattended":"block","revert.merge":"true","run.subagent_max_concurrent":"4","run.subagent_max_depth":"2","run.subagent_max_exchanges":"8","sandbox.env_exclude":"[]","sandbox.env_include_only":"[]","sandbox.env_inherit":"allowlist","sandbox.mode":"danger-full-access","sandbox.network":"restricted","sandbox.read":"project","sandbox.readable_roots":"[]","sandbox.require":"enforced","sandbox.writable_roots":"[]","shell":"/bin/sh","skills.builtin":"true","skills.catalog_max_bytes":"8192","skills.compat":"true","skills.disabled":"[]","skills.enabled":"true","skills.paths":"[]","skills.project":"true","tools.editor":"auto","tui.diff_layout":"auto","tui.mouse":"true","tui.theme":"mentat-dark","tui.theme_dark":"mentat-dark","tui.theme_light":"mentat-light","tui.thinking":"true","web.allow_private_network":"false","web.enabled":"false","web.fetch_max_bytes":"5242880","web.max_timeout_ms":"120000","web.output_max_chars":"100000","web.search_provider":"exa","web.timeout_ms":"30000","workspace.tooling":"auto"}}

--origins annotates each value with its source. With nothing configured, every
value is a default except the env-provided sandbox mode.

  $ mentat config show --origins | censor
  commands.compat=true (default)
  commands.disabled=[] (default)
  commands.enabled=true (default)
  commands.project=true (default)
  compaction.auto=true (default)
  dune.lint_command=["litany","check","--no-build","--trust-build"] (default)
  dune.targets=["@check"] (default)
  dune.watch=auto (default)
  image.max_bytes=5242880 (default)
  image.max_count=20 (default)
  image.max_dimension=8000 (default)
  instructions.claude_md=true (default)
  instructions.global=true (default)
  instructions.project=true (default)
  instructions.project_max_bytes=32768 (default)
  notices.cr_comments=true (default)
  notices.dune_diagnostics=true (default)
  notices.fswatch=true (default)
  notify.channel=auto (default)
  notify.command=[] (default)
  notify.enabled=true (default)
  notify.on=["turn-done","decision"] (default)
  notify.when=unfocused (default)
  ocaml.merlin_program=["ocamlmerlin"] (default)
  permission.unattended=block (default)
  revert.merge=true (default)
  run.subagent_max_concurrent=4 (default)
  run.subagent_max_depth=2 (default)
  run.subagent_max_exchanges=8 (default)
  sandbox.env_exclude=[] (default)
  sandbox.env_include_only=[] (default)
  sandbox.env_inherit=allowlist (default)
  sandbox.mode=danger-full-access (env)
  sandbox.network=restricted (default)
  sandbox.read=project (default)
  sandbox.readable_roots=[] (default)
  sandbox.require=enforced (default)
  sandbox.writable_roots=[] (default)
  shell=/bin/sh (default)
  skills.builtin=true (default)
  skills.catalog_max_bytes=8192 (default)
  skills.compat=true (default)
  skills.disabled=[] (default)
  skills.enabled=true (default)
  skills.paths=[] (default)
  skills.project=true (default)
  tools.editor=auto (default)
  tui.diff_layout=auto (default)
  tui.mouse=true (default)
  tui.theme=mentat-dark (default)
  tui.theme_dark=mentat-dark (default)
  tui.theme_light=mentat-light (default)
  tui.thinking=true (default)
  web.allow_private_network=false (default)
  web.enabled=false (default)
  web.fetch_max_bytes=5242880 (default)
  web.max_timeout_ms=120000 (default)
  web.output_max_chars=100000 (default)
  web.search_provider=exa (default)
  web.timeout_ms=30000 (default)
  workspace.tooling=auto (default)
  workspace_trust=trusted

Setting user values re-renders the changed keys in place and marks their origin
as (user); a base URL carrying no credential shows verbatim (see secrets.t for
one that does) and the sandbox mode stays (env).

  $ mentat config set model openai/gpt-5.6-sol >/dev/null
  $ mentat config set run.max_steps 9 >/dev/null
  $ mentat config set providers.openai.base_url https://api.openai.example/v1 >/dev/null
  $ mentat config show | grep -E '^(model|run.max_steps|providers.openai.base_url)='
  model=openai/gpt-5.6-sol
  providers.openai.base_url=https://api.openai.example/v1
  run.max_steps=9
  $ mentat config show --origins | grep -E '^(model|run.max_steps|sandbox.mode)='
  model=openai/gpt-5.6-sol (user)
  run.max_steps=9 (user)
  sandbox.mode=danger-full-access (env)
