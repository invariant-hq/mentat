A trigger host records its provenance on the turn it admits: `run start
--triggered <source>@<digest>:<key>` mints a triggered origin instead of a
user one, so the journal attributes the turn to the trigger. Provenance is
attribution, never authority — the turn runs as an ordinary prompt turn.

  $ use_trusted_workspace
  $ cat > trig.jsonl <<'JSONL'
  > {"expect":{"body_contains":["review the delivery"]},"response":{"id":"t1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"reviewed"}]}]}}
  > JSONL
  $ start_fake_openai trig.jsonl capture-trig port-trig
  $ mentat run start --json --triggered "nightly-review@0f9a4c1d2e3b4a5f:delivery-42" --cwd "$PWD" --id trig "review the delivery" >trig.out 2>/dev/null
  $ wait_fake_server
  $ grep '"type":"turn.started"' trig.out | mentat_cram json .origin
  triggered
  $ grep '"type":"turn.finished"' trig.out | mentat_cram json .text
  reviewed

A malformed --triggered value is a usage error before any run.

  $ mentat run start --triggered "not-a-provenance" --cwd "$PWD" --id trigbad "x" 2>&1
  mentat: invalid --triggered value not-a-provenance: expected <source>@<digest>:<key>
  [2]

The digest is pinned to the charter policy digest's 16 lowercase hex
characters; any other length is refused the same way.

  $ mentat run start --triggered "nightly-review@0f9a4c1d:delivery-42" --cwd "$PWD" --id trigshort "x" 2>&1
  mentat: invalid --triggered value nightly-review@0f9a4c1d:delivery-42: expected <source>@<digest>:<key>
  [2]
