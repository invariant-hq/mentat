Auth command fixes. No credentials are stored; the hermetic home has none.

AUTH-4 — a credential-optional provider (local) keeps the honest
Missing account phase but exits 0: credential absence does not block its route.

  $ use_trusted_workspace
  $ mentat auth status local 2>&1 | tr -s ' '
  PROVIDER PHASE CONNECTED
  local missing no
  $ mentat auth status local >/dev/null 2>&1; echo $?
  0

A credential-requiring provider with no credential still reads missing and, as a
single-provider view, exits 1.

  $ mentat auth status anthropic 2>&1 | tr -s ' '
  PROVIDER PHASE CONNECTED
  anthropic missing no
  [1]
  $ mentat auth status anthropic >/dev/null 2>&1; echo $?
  1

One bad provider route remains visible without erasing a healthy route. The
batch preserves provider order/cardinality and reports the resolver failure
instead of lowering it to Missing.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ printf '{"version":1,"credentials":{"anthropic":{"default":{"kind":"bearer","token":"wrong-kind"}}}}' > "$XDG_CONFIG_HOME/mentat/auth.json"
  $ chmod 600 "$XDG_CONFIG_HOME/mentat/auth.json"
  $ export OPENAI_API_KEY=healthy-openai-key
  $ mentat auth status >status.txt 2>errors.txt
  $ grep '^openai ' status.txt | tr -s ' '
  openai unchecked yes
  $ grep '^anthropic ' status.txt | tr -s ' '
  anthropic resolution-failed no
  $ grep -o '^anthropic: credential .* kind bearer' errors.txt
  anthropic: credential from store(default) has kind bearer
  $ unset OPENAI_API_KEY
  $ rm "$XDG_CONFIG_HOME/mentat/auth.json"

Account-consuming commands read the store live: a save and a logout become
visible to the very next status without cache invalidation vocabulary.

  $ printf 'ollama-live-key' | mentat auth save ollama --api-key-stdin >/dev/null
  $ mentat auth status ollama | tail -n 1 | tr -s ' '
  ollama unchecked yes
  $ mentat auth logout ollama >/dev/null
  $ mentat auth status ollama | tail -n 1 | tr -s ' '
  ollama missing no

AUTH-5 — an unknown provider is a usage error naming the known set, not an empty
table with exit 1.

  $ mentat auth status bogusprovider 2>&1
  mentat: unknown provider "bogusprovider"; known providers: openai, anthropic, google, local, ollama, opencode-go
  [2]
