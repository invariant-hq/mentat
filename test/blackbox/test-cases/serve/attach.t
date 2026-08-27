A real turn driven through the daemon, then the session-lifecycle --attach
round-trips (rename / export / revert) reaching the daemon's online cones over
the wire. A workspace instance resolves against the environment of the client
whose handshake boots it, and keeps it for the instance's life — so the fake
provider is configured before the first attach, and a LATER client's env does
not reach the already-booted instance (the boot-env rule; attach-env.t proves
the boot half).

  $ use_trusted_workspace
  $ export MENTAT_NOW=1753000000000
  $ trap stop_daemon EXIT

The fake provider is wired before the first attach, so the instance's boot
environment makes the turn's provider call.

One multi-response fake serves every turn: the instance uses the provider it
captured at boot, so a second fake for a later turn would be unreachable (the
boot-env rule). Line 1 answers the first turn; line 2 (a long delay_ms) is
the slow turn that holds the fence below.

  $ cat > script.jsonl <<'JSONL'
  > {"expect":{"body_contains":["through the daemon"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"daemon answer"}]}]}}
  > {"delay_ms":10000,"expect":{"body_contains":["slow work"]},"response":{"id":"s1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"slow done"}]}]}}
  > JSONL
  $ start_fake_openai script.jsonl
  $ start_daemon

A run --attach drives the turn on the daemon's engine; the assistant text comes
back over the wire.

  $ mentat run start --attach --id demo "through the daemon" --cwd "$PWD" 2>/dev/null
  daemon answer

The turn reached the daemon's captured provider (the request carries the
captured model), and the session is durable and listable through the daemon.

  $ grep -o '"model":"gpt-5.6-sol"' capture/request-1.json
  "model":"gpt-5.6-sol"
  $ mentat session list --attach --cwd "$PWD" | censor
  ID    PHASE  AGE  TITLE
  demo  idle   0s

rename --attach commits through the daemon's Lifecycle cone under the fence the
daemon already holds — not the offline twin, which would lose the CAS to the
daemon and report Busy.

  $ mentat session rename demo "renamed" --attach --cwd "$PWD"
  demo
  $ mentat session show demo --cwd "$PWD" | grep -E '^title='
  title=renamed

export --attach json returns the whole integrity-verified bundle over the wire
(the online export cone); the terminal manifest closes it.

  $ mentat session export demo --format json --attach --cwd "$PWD" > bundle.ndjson
  $ grep -o '"export":"mentat.session"' bundle.ndjson
  "export":"mentat.session"
  $ grep -o '"section":"end"' bundle.ndjson
  "section":"end"

revert --apply --attach reaches the online revert cone on the daemon's engine;
this turn wrote no files, so the settlement is a clean no-op.

  $ mentat session revert --apply --latest --attach demo --cwd "$PWD"
  nothing to revert

--attach with a non-json export format is a usage error, never a silent offline
fallback (text/markdown/html render offline, fence-free).

  $ mentat session export demo --format text --attach --cwd "$PWD" 2>&1
  mentat: --attach is only supported with --format json; text, markdown, and html export run offline
  [2]

A slow turn driven through the daemon holds the fence (the capture-file
rendezvous proves it is in-turn). An OFFLINE mutating command against that
session is D17-correctly Busy — but because the owner is a live daemon
(discovery present, claim held) the message points the user at --attach (4e,
rendering only, no behavior change).

  $ mentat run start --attach --id slow "slow work" --cwd "$PWD" >slow.out 2>&1 &
  $ SLOW_PID=$!
  $ wait_for_file capture/request-2.json
  $ mentat session archive slow --cwd "$PWD" 2>&1 | censor | mentat_cram subst 'pid \$PID on \S+' 'pid $PID on $HOST'
  mentat: session slow is busy with another driver
  serve-mount (pid $PID on $HOST
  the mentat daemon drives this session; re-run with --attach
  [1]
  $ kill -9 "$SLOW_PID" 2>/dev/null; kill -9 "$MENTAT_FAKE_PROVIDER_PID" 2>/dev/null; wait "$SLOW_PID" 2>/dev/null; wait "$MENTAT_FAKE_PROVIDER_PID" 2>/dev/null; true

The daemon is killed hard (SIGKILL) — no graceful settle. Its run fences are
kernel-released and the store is left uncorrupted: the durable session survives
the crash, still listable and readable offline, ready for a successor to
re-drive.

  $ kill -9 "$MENTAT_DAEMON_PID"; wait "$MENTAT_DAEMON_PID" 2>/dev/null; true
  $ MENTAT_DAEMON_PID=
  $ mentat session show demo --cwd "$PWD" | grep -E '^(id|phase|lifecycle)='
  id=demo
  phase=idle
  lifecycle=active
  $ mentat session list --cwd "$PWD" | grep -c demo
  1
