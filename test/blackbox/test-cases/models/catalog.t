The model catalog is reported through the [model_readiness] query, so each row
carries live per-model actionability alongside its
static metadata: MODEL/STATUS/CONTEXT/COST $/MTOK/READINESS. A trailing [*] marks
each provider's declared default model. COST is the base-tier per-million rate
from the model's pricing (MOD-3 reversed for cost; the prior CLI's memory-FIT
column stays absent — it has no next surface). READINESS is the effective
provider-route actionability: [ready], [sign-in], [blocked], [unavailable], or a
credential error — in a trusted workspace with no credentials, every
authentication-requiring provider reads [sign-in] and the credential-free local
provider reads [ready].

  $ use_trusted_workspace
  $ mentat models list
  MODEL                          STATUS   CONTEXT  COST $/MTOK  READINESS
  openai/gpt-5.6-sol *           stable   1050000  5/30         sign-in
  openai/gpt-5.6-terra           stable   1050000  2.5/15       sign-in
  openai/gpt-5.6-luna            stable   1050000  1/6          sign-in
  openai/gpt-5.5-pro             stable   1050000  30/180       sign-in
  openai/gpt-5.4-mini            stable   400000   0.75/4.5     sign-in
  openai/gpt-5.4-nano            stable   400000   0.2/1.25     sign-in
  openai/gpt-5.3-codex           stable   400000   1.75/14      sign-in
  openai/gpt-image-2             stable   -        5/30         sign-in
  anthropic/claude-sonnet-5 *    stable   1000000  2/10         sign-in
  anthropic/claude-fable-5       stable   1000000  10/50        sign-in
  anthropic/claude-opus-5        stable   1000000  5/25         sign-in
  anthropic/claude-haiku-4-5     stable   200000   1/5          sign-in
  google/gemini-3.6-flash *      stable   1048576  1.5/7.5      sign-in
  google/gemini-3.5-flash-lite   stable   1048576  0.3/2.5      sign-in
  google/gemini-3.1-pro-preview  preview  1048576  2/12         sign-in
  local/qwen3-coder-30b *        stable   262144   -            ready
  local/gpt-oss-20b              stable   131072   -            ready
  local/devstral-small-2         stable   393216   -            ready
  local/qwen3.6-35b              stable   262144   -            ready
  ollama/gpt-oss:20b             stable   -        -            ready
  opencode-go/kimi-k2.7-code *   stable   262144   0.95/4       sign-in
  opencode-go/kimi-k3            stable   1048576  3/15         sign-in
  opencode-go/glm-5.3            stable   1000000  1.4/4.4      sign-in
  opencode-go/deepseek-v4-pro    stable   1000000  1.32/3.96    sign-in
  opencode-go/deepseek-v4-flash  stable   1000000  0.44/1.32    sign-in
  opencode-go/mimo-v2.5-pro      stable   1048576  0.435/0.87   sign-in
  opencode-go/mimo-v2.5          stable   1000000  0.14/0.28    sign-in
  opencode-go/hy3                stable   256000   0.14/0.58    sign-in
  opencode-go/minimax-m3         stable   1000000  0.3/1.2      sign-in
  opencode-go/qwen3.8-max        stable   1000000  2/6          sign-in
  opencode-go/qwen3.7-plus       stable   1000000  0.4/1.6      sign-in
  * provider default

`--all` additionally reveals hidden and unavailable models: the OpenAI chat
alias surfaces with its unavailable status inline (widening the STATUS column).
A default `list` hides it.

  $ mentat models list --all
  MODEL                          STATUS                                                          CONTEXT  COST $/MTOK  READINESS
  openai/gpt-5.6-sol *           stable                                                          1050000  5/30         sign-in
  openai/gpt-5.6-terra           stable                                                          1050000  2.5/15       sign-in
  openai/gpt-5.6-luna            stable                                                          1050000  1/6          sign-in
  openai/gpt-5.5-pro             stable                                                          1050000  30/180       sign-in
  openai/gpt-5.4-mini            stable                                                          400000   0.75/4.5     sign-in
  openai/gpt-5.4-nano            stable                                                          400000   0.2/1.25     sign-in
  openai/gpt-5.3-codex           stable                                                          400000   1.75/14      sign-in
  openai/gpt-image-2             stable                                                          -        5/30         sign-in
  openai/gpt-5.3-chat-latest     unavailable: OpenAI Responses does not support this chat alias  128000   1.75/14      sign-in
  anthropic/claude-sonnet-5 *    stable                                                          1000000  2/10         sign-in
  anthropic/claude-fable-5       stable                                                          1000000  10/50        sign-in
  anthropic/claude-opus-5        stable                                                          1000000  5/25         sign-in
  anthropic/claude-haiku-4-5     stable                                                          200000   1/5          sign-in
  google/gemini-3.6-flash *      stable                                                          1048576  1.5/7.5      sign-in
  google/gemini-3.5-flash-lite   stable                                                          1048576  0.3/2.5      sign-in
  google/gemini-3.1-pro-preview  preview                                                         1048576  2/12         sign-in
  local/qwen3-coder-30b *        stable                                                          262144   -            ready
  local/gpt-oss-20b              stable                                                          131072   -            ready
  local/devstral-small-2         stable                                                          393216   -            ready
  local/qwen3.6-35b              stable                                                          262144   -            ready
  ollama/gpt-oss:20b             stable                                                          -        -            ready
  opencode-go/kimi-k2.7-code *   stable                                                          262144   0.95/4       sign-in
  opencode-go/kimi-k3            stable                                                          1048576  3/15         sign-in
  opencode-go/glm-5.3            stable                                                          1000000  1.4/4.4      sign-in
  opencode-go/deepseek-v4-pro    stable                                                          1000000  1.32/3.96    sign-in
  opencode-go/deepseek-v4-flash  stable                                                          1000000  0.44/1.32    sign-in
  opencode-go/mimo-v2.5-pro      stable                                                          1048576  0.435/0.87   sign-in
  opencode-go/mimo-v2.5          stable                                                          1000000  0.14/0.28    sign-in
  opencode-go/hy3                stable                                                          256000   0.14/0.58    sign-in
  opencode-go/minimax-m3         stable                                                          1000000  0.3/1.2      sign-in
  opencode-go/qwen3.8-max        stable                                                          1000000  2/6          sign-in
  opencode-go/qwen3.7-plus       stable                                                          1000000  0.4/1.6      sign-in
  * provider default

  $ mentat models list | grep -c gpt-5.3-chat-latest
  0
  [1]
  $ mentat models list --all | grep -c gpt-5.3-chat-latest
  1

Provider filtering narrows to one provider's catalog.

  $ mentat models list --provider openai
  MODEL                 STATUS  CONTEXT  COST $/MTOK  READINESS
  openai/gpt-5.6-sol *  stable  1050000  5/30         sign-in
  openai/gpt-5.6-terra  stable  1050000  2.5/15       sign-in
  openai/gpt-5.6-luna   stable  1050000  1/6          sign-in
  openai/gpt-5.5-pro    stable  1050000  30/180       sign-in
  openai/gpt-5.4-mini   stable  400000   0.75/4.5     sign-in
  openai/gpt-5.4-nano   stable  400000   0.2/1.25     sign-in
  openai/gpt-5.3-codex  stable  400000   1.75/14      sign-in
  openai/gpt-image-2    stable  -        5/30         sign-in
  * provider default

`ollama` is a known provider (accepted by show/select/download) that ships no
catalog models, so its filtered listing is the bare header and it never appears
in `list --all` (MOD-4).

  $ mentat models list --provider ollama
  MODEL               STATUS  CONTEXT  COST $/MTOK  READINESS
  ollama/gpt-oss:20b  stable  -        -            ready
  $ mentat models list --all | grep -c ollama
  1

The `--json` catalog is one envelope. Each entry extends the prior selector,
status, and context window compatibly with the provider-default flag, the
base-tier cost lanes, and the readiness projection (availability, actionability,
and the route's authentication requirement). No memory-fit field is emitted (the
FIT half of MOD-3 stands).

  $ mentat models list --json | mentat_cram json '.type'
  models
  $ mentat models list --json | mentat_cram json '.models[0]'
  {"model":"openai/gpt-5.6-sol","status":"stable","context_window":1050000,"provider_default":true,"cost":{"input_per_million":5,"output_per_million":30},"readiness":{"availability":"unknown","actionability":"provider_blocked","auth_required":true}}
  $ mentat models list --json | mentat_cram json '.models[0].readiness.actionability'
  provider_blocked

`models show` reports one model's metadata as key=value lines and as a single
`model` envelope in `--json`; neither carries a cost or fit field (MOD-3).

  $ mentat models show openai/gpt-5.6-sol
  model=openai/gpt-5.6-sol
  status=stable
  context_window=1050000
  display_name=GPT-5.6 Sol
  $ mentat models show openai/gpt-5.6-sol --json
  {"schema_version":1,"type":"model","model":"openai/gpt-5.6-sol","status":"stable","context_window":1050000,"max_output_tokens":128000,"display_name":"GPT-5.6 Sol"}

`show` resolves an unavailable model directly (it need not be selectable) and
surfaces the unavailable status verbatim.

  $ mentat models show openai/gpt-5.3-chat-latest
  model=openai/gpt-5.3-chat-latest
  status=unavailable: OpenAI Responses does not support this chat alias
  context_window=128000
  display_name=GPT-5.3 Chat (latest)

An explicit GGUF path resolves as a dynamic model under the local provider: the
selector is the path, the display name is the file, and resolution is pure — the
file need not exist.

  $ mentat models show "local/$PWD/tiny.gguf" | censor
  model=local/$TESTCASE_ROOT/tiny.gguf
  status=stable
  context_window=-
  display_name=tiny.gguf

Unknown providers and models are usage errors (exit 2), and a bare id without a
provider is rejected with a canonical-selector hint.

  $ mentat models show bogus/nope 2>&1
  mentat: unknown provider "bogus"; known providers: openai, anthropic, google, local, ollama, opencode-go
  [2]
  $ mentat models show openai/no-such-model 2>&1
  mentat: unknown model "no-such-model" for provider "openai"; known models: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5-pro, gpt-5.4-mini, gpt-5.4-nano, gpt-5.3-codex, gpt-image-2, gpt-5.3-chat-latest
  [2]
  $ mentat models show gpt-5.6-sol 2>&1
  mentat: model selector "gpt-5.6-sol" is invalid: model selector must be in the form provider/model; known models: openai/gpt-5.6-sol
  [2]
