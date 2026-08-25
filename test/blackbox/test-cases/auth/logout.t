Logout is one typed settlement. Ordinary logout is idempotent; `--revoke`
reports the provider-side outcome, conditional local removal, and the exact
credential source that wins after settlement.

  $ use_trusted_workspace
  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ oauth_credential () {
  >   printf '{"version":1,"credentials":{"openai":{"default":{"kind":"oauth","access_token":"oauth-access-9999","refresh_token":"refresh-r1","account_id":"acct-42"}}}}' > "$XDG_CONFIG_HOME/mentat/auth.json"
  >   chmod 600 "$XDG_CONFIG_HOME/mentat/auth.json"
  > }

Successful remote revocation removes the observed local credential and reports
that no credential source remains.

  $ oauth_credential
  $ cat > revoke-ok.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/oauth/revoke HTTP/1.1","body_contains":["\"token_type_hint\":\"refresh_token\""]},"http":{"status":200,"json":{}}}
  > JSONL
  $ start_fake_issuer revoke-ok.jsonl cap-revoke-ok port-revoke-ok
  $ mentat auth logout openai --revoke
  Remote revocation succeeded.
  Removed openai credential default.
  Current credential source: none.
  $ wait_fake_server
  $ mentat_cram json .credentials.openai.default.kind "$XDG_CONFIG_HOME/mentat/auth.json"
  mentat_cram json: no member "openai"
  [1]

An external writer that ignores Mentat's credential lock can replace the slot
while remote revocation is in flight. Conditional removal preserves that value,
and `current` identifies the stored replacement rather than reconstructing state
from the revoke request.

  $ oauth_credential
  $ cat > revoke-held.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/oauth/revoke HTTP/1.1"},"delay_ms":1000,"http":{"status":200,"json":{}}}
  > JSONL
  $ start_fake_issuer revoke-held.jsonl cap-revoke-held port-revoke-held
  $ mentat auth logout openai --revoke >replaced.out 2>replaced.err & revoker=$!
  $ wait_for_file cap-revoke-held/request-1.json
  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"api_key","api_key":"replacement-key"}}}}' > "$XDG_CONFIG_HOME/mentat/auth.json"
  $ chmod 600 "$XDG_CONFIG_HOME/mentat/auth.json"
  $ wait "$revoker"
  $ cat replaced.out
  Remote revocation succeeded.
  Kept replacement openai credential default written during revocation.
  Current credential source: store(default).
  $ cat replaced.err
  $ wait_fake_server
  $ grep -c replacement-key "$XDG_CONFIG_HOME/mentat/auth.json"
  1

A provider-side failure remains a settlement fact: the local credential is
still removed, the problem is presented as a warning, and the command succeeds.

  $ oauth_credential
  $ cat > revoke-failed.jsonl <<'JSONL'
  > {"expect":{"request_line":"POST /v1/oauth/revoke HTTP/1.1"},"http":{"status":500,"json":{"error":{"message":"temporarily unavailable"}}}}
  > JSONL
  $ start_fake_issuer revoke-failed.jsonl cap-revoke-failed port-revoke-failed
  $ mentat auth logout openai --revoke >failed.out 2>failed.err
  $ wait_fake_server
  $ cat failed.out
  Removed openai credential default.
  Current credential source: none.
  $ grep -o 'remote revocation failed ([^)]*)' failed.err | sed -E 's/\([^)]*\)/(problem)/'
  remote revocation failed (problem)

API keys have no remote revoke route. Unsupported is reported without a network
request, followed by the successful local settlement.

  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"api_key","api_key":"stored-key"}}}}' > "$XDG_CONFIG_HOME/mentat/auth.json"
  $ chmod 600 "$XDG_CONFIG_HOME/mentat/auth.json"
  $ mentat auth logout openai --revoke
  The stored credential does not support provider revocation.
  Removed openai credential default.
  Current credential source: none.

Requested revocation of an empty slot is distinct from unsupported revocation.

  $ mentat auth logout openai --revoke
  No stored credential was available for revocation.
  Current credential source: none.

Ordinary logout has one idempotent presentation. If an environment credential
wins after local removal, the canonical post-settlement discovery names it.

  $ printf '{"version":1,"credentials":{"openai":{"default":{"kind":"api_key","api_key":"stored-key"}}}}' > "$XDG_CONFIG_HOME/mentat/auth.json"
  $ chmod 600 "$XDG_CONFIG_HOME/mentat/auth.json"
  $ OPENAI_API_KEY=environment-key mentat auth logout openai
  Logged out of openai.
  Current credential source: env(OPENAI_API_KEY).
  $ mentat auth logout openai
  Logged out of openai.
  Current credential source: none.

An unknown provider is rejected as command input before any runtime mutation.

  $ mentat auth logout bogusprovider 2>&1
  mentat: unknown provider "bogusprovider"; known providers: openai, anthropic, google, local, ollama, opencode-go
  [2]
