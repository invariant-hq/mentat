The boot race's loser never severs the winner. A serve boot binds its
listener only AFTER the fence-taking attach, so a second serve of an
already-served session loses the fence before it ever touches the socket
path: it exits refused, and the winner's endpoint still answers — a send
is delivered over the wire into the winner's live journal. A virgin root
with no mail keeps serving until something drives it, so the winner stays
up for the probes.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat session create --id solo --cwd "$PWD" >/dev/null
  $ mentat serve --session solo --cwd "$PWD" >winner-serve.out 2>&1 &
  $ WINNER_PID=$!
  $ wait_for_file winner-serve.out

The loser refuses at its attach, naming the winner; it never reaches the
bind.

  $ mentat serve --session solo --cwd "$PWD" 2>&1 | censor | mentat_cram subst 'pid \$PID on \S+' 'pid $PID on $HOST'
  mentat: session solo: attach: session solo is busy with another driver
  serve-session (pid $PID on $HOST
  [1]

The winner's endpoint survived the loser: a send still crosses the wire
into the live journal.

  $ mentat session send solo "still alive?" --cwd "$PWD"
  delivered solo

Wind down: a graceful stop removes the endpoint.

  $ kill "$WINNER_PID"
  $ wait_exit "$WINNER_PID"
  0
  $ test ! -e "$SOCK_BASE/solo" && echo endpoint-removed
  endpoint-removed
