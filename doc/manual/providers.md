# Providers and accounts

Mentat separates three choices that other clients often combine:

1. a provider declaration says which models, authentication methods, and wire
   protocol exist;
2. an account resolves a credential for that provider;
3. a model selector chooses the model used by a turn.

Changing a model does not change credentials, and logging in does not silently
rewrite the selected model.

## Quick setup

Use the provider's default login method, confirm credential presence and model
readiness, then choose a model:

```sh
mentat auth login anthropic
mentat auth status anthropic
mentat models list --provider anthropic
mentat models select anthropic/MODEL
```

`mentat auth login` prompts for API keys with terminal echo disabled. For a
script, read the key from standard input instead of putting it in an argument:

```sh
printenv OPENAI_API_KEY | mentat auth save openai --api-key-stdin
```

The TUI exposes the same workflows through `/login`, `/logout`, and `/model`.

## Built-in providers

| Provider | Authentication | Model source |
| --- | --- | --- |
| `openai` | Browser OAuth, ChatGPT device code, API key, or `OPENAI_API_KEY` | Built-in OpenAI catalog; uses the Responses API. |
| `anthropic` | API key or `ANTHROPIC_API_KEY` | Built-in Anthropic catalog. |
| `google` | API key, `GOOGLE_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, or `GEMINI_API_KEY` | Built-in Gemini catalog. |
| `local` | None | Managed local models or an explicit `.gguf` model path. |
| `ollama` | Optional API key or `OLLAMA_API_KEY` | Dynamic: the configured daemon owns its model ids. |
| `opencode-go` | API key or `OPENCODE_API_KEY` | The OpenCode Go gateway owns its model set; the server listing supplies model ids and metadata at runtime. |

Run `mentat models list --all` for the current catalog, model status, cost, and
credential readiness.
Provider defaults and model metadata change with the catalog, so the command
output — not a copied list in this manual — is authoritative.

## Login methods and storage

OpenAI declares three login method ids:

```sh
mentat auth login openai --method browser
mentat auth login openai --method device-code
mentat auth login openai --method api-key
```

Anthropic, Google, Ollama, and OpenCode Go currently declare `api-key`.
Omitting `--method` lets the provider choose its default interactive method.
Without a terminal, select an explicit non-interactive method; API-key input
additionally needs `--api-key-stdin`.

Stored credentials live in `$MENTAT_CONFIG_HOME/auth.json` when the explicit
config-home override is set. Otherwise the path is
`$XDG_CONFIG_HOME/mentat/auth.json` or `~/.config/mentat/auth.json`. Mentat creates
the config directory with mode `0700` and atomically replaces the file with mode
`0600`. Do not commit or hand-author this file.

Credentials may be named within one provider:

```sh
printenv WORK_OPENAI_API_KEY | \
  mentat auth save openai --name work --api-key-stdin
mentat auth remove openai --name work
```

`--name` selects the stored slot changed by login, save, logout, or remove.
Ordinary model calls and `auth status` use the `default` stored slot; status has
no `--name` option. A non-empty environment credential still takes precedence.

## Credential precedence

Resolution is deterministic. For CLI use, the provider's first non-empty
environment variable wins, followed by the selected stored credential.

An empty environment variable is ignored. `auth status` reports only the phase
and whether the provider is connected; it never prints the credential value,
source, or fingerprint.

Removing or logging out affects the store only. If an environment credential
is active, Mentat reports that it remains active and cannot be removed from the
calling process.

## Status and login-time checks

`mentat auth status [PROVIDER]` is passive: it reads declarations, environment,
and the local store without contacting a provider or refreshing OAuth tokens.
Its observable phases are:

| Phase | Meaning |
| --- | --- |
| `missing` | No credential resolved for the provider route. |
| `unchecked` | A credential resolved; passive status did not validate it. |
| `resolution-failed` | Credential data exists but could not be resolved. |

With no provider argument, status lists every route and exits 0 even if one
route is missing or damaged. A named authentication-required provider exits 1
when it is missing or unresolved; credential-optional `local` and `ollama`
routes remain usable without a credential.

`auth login` and `auth save` persist the credential and then perform the
provider's account check when one is available. Their `Checked:` line may report
`unchecked`, `ready`, `degraded`, or `blocked`; a blocked check exits 1 but leaves
the newly saved credential in place. These check results are not persisted, so
the next passive status reports that credential as `unchecked`.

There is no `auth status --refresh` option. OAuth access tokens are refreshed by
provider runtime policy when a model call needs it, not by status. Secret
material never enters account status, diagnostics, or session events.

`mentat auth logout PROVIDER --revoke` attempts provider revocation for a stored
OAuth credential before removing it locally. A revocation failure produces a
warning but does not strand the local credential. API keys cannot be revoked
through Mentat and are removed locally.

## Selecting models

Model selectors use `provider/model`:

```sh
mentat models list                    # visible catalog
mentat models show provider/model     # model details and metadata
mentat models current                 # effective main and small choices
mentat models select provider/model
```

`models current` prints the resolved main and small choices. `models select`
writes user configuration; use `config set model provider/model --project` or
`--project-local` for the project layers described in
[Configuration](configuration.md). A one-run override uses
`--model provider/model` or `MENTAT_MODEL`.

Managed local models expose `mentat models download MODEL` to fetch weights
explicitly; first use also prepares a missing managed artifact. Only local
models are downloadable.

## OpenCode Go

The `opencode-go` provider is a hosted subscription gateway at
`https://opencode.ai/zen/go` (override with `providers.opencode-go.base_url`
or `MENTAT_OPENCODE_GO_BASE_URL`). The gateway owns its model set — ids are
whatever it serves, such as `kimi-k3` — and Mentat curates the models it
vouches for while the server listing supplies every other model at runtime.
`mentat models list --provider opencode-go` shows the current set.

```sh
mentat auth login opencode-go
mentat models select opencode-go/kimi-k3
```

The gateway distinguishes two wire protocols: most models ride its
OpenAI-compatible chat-completions endpoint, some its Anthropic-compatible
messages endpoint. Mentat routes each model by the protocol its metadata
declares, so any gateway-served id is usable without choosing a route.

## OpenAI-compatible servers

Use the `ollama` provider for servers implementing the OpenAI
**chat-completions** endpoint (`POST /v1/chat/completions`), including Ollama,
llama.cpp, vLLM, and LM Studio. Configure the server root; Mentat appends the
endpoint path:

```sh
mentat config set providers.ollama.base_url http://127.0.0.1:8080
mentat config set model ollama/your-model-id
```

or for one shell:

```sh
export MENTAT_OLLAMA_BASE_URL=http://127.0.0.1:8080
export MENTAT_MODEL=ollama/your-model-id
```

The daemon owns the model set, so any non-empty `ollama/MODEL` id is routed to
it; Mentat does not call `GET /v1/models`. A local daemon needs no credential.
For a protected deployment, set `OLLAMA_API_KEY` or save an Ollama API key.

Do not point `providers.openai.base_url` at a chat-completions-only server. The
`openai` provider uses the OpenAI **Responses** endpoint (`POST /v1/responses`)
and validates model ids against its built-in catalog; it is a different wire
contract despite the similar name.
