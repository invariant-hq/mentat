Concurrency fence across two live processes (#5). The capture-file rendezvous makes
the timing race-free: the fake writes capture/request-N.json AFTER the held process
acquires the store lock and sends its request but BEFORE the delay_ms hold, so
wait_captured is a happens-before edge — process 1 is provably in-turn (lock held)
before the second process acts. hold_run redirects the held turn's own output to a
file, so only process 2's frame is pinned. The busy-owner line names a pid + host,
both scrubbed ($PID via censor, the host via a subst).

  $ cat > hold.jsonl <<'JSONL'
  > {"delay_ms":10000,"expect":{"body_contains":["work"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL
  $ start_fake_openai hold.jsonl
  $ use_trusted_workspace
  $ hold_run held "work"
  $ wait_captured 1

Process 2 cannot touch the fenced session while process 1 holds it: a mutating
command reports the busy owner (pid + host, both scrubbed) and exits 1, without
corrupting the session.

  $ mentat session archive held --cwd "$PWD" 2>&1 | censor | mentat_cram subst 'pid \$PID on \S+' 'pid $PID on $HOST'
  mentat: session held is busy with another driver
  serve-session (pid $PID on $HOST
  [1]

Release the held owner (it is mid-hold under the long delay_ms) with SIGINT; it
cancels and exits 130 (the interrupt convention), settling the session to idle.

  $ kill -INT "$MENTAT_HELD_PID"
  $ wait_exit "$MENTAT_HELD_PID"
  130

After the owner settles, the session is idle and archivable — no lock was stranded.

  $ mentat session show held --cwd "$PWD" | grep -E '^phase='
  phase=idle

The settled agent's linger, from the offline side. A raised linger keeps
the agent provably alive when the next two commands land, with NO pacing
between them — that is the assertion. The json export of the served
session rides the wire to the live agent's own export cone and serves the
integrity-verified bundle; the rename — an offline fenced write — waits
the linger out on the bounded patience instead of answering Busy.

  $ SOCK_BASE="$(child_sock_base)"
  $ export MENTAT_CHILD_LINGER=2
  $ cat > quick.jsonl <<'JSONL'
  > {"expect":{"body_contains":["quick work"]},"response":{"id":"q1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"quick done"}]}]}}
  > JSONL
  $ start_fake_openai quick.jsonl capture-quick port-quick
  $ mentat run start --id linger "quick work" --cwd "$PWD" 2>/dev/null
  quick done
  $ wait_fake_server
  $ mentat session export linger --format json --cwd "$PWD" 2>/dev/null > linger-bundle.jsonl
  $ head -c 60 linger-bundle.jsonl; echo
  {"export":"mentat.session","format_version":2,"document_vers
  $ grep -o '"section":"end"' linger-bundle.jsonl
  "section":"end"
  $ mentat session rename linger "renamed-through-the-linger" --cwd "$PWD"
  linger
  $ mentat session show linger --cwd "$PWD" | grep -E '^title='
  title=renamed-through-the-linger
  $ wait_child_exit linger
