The gone backstop: a served session whose store is removed out from under
its agent — a reclaimed harness sandbox, a deleted ephemeral home — must
not leave an immortal server. The document stays continuously absent, so
the serve ends itself within the backstop (about five seconds) and its
teardown removes the endpoint. A virgin root never idles (no settled head
yet), so nothing but the backstop can end this server.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ mentat session create --id ghost --cwd "$PWD" >/dev/null
  $ mentat serve --session ghost --cwd "$PWD" >ghost-serve.out 2>&1 &
  $ GHOST_PID=$!
  $ wait_for_file ghost-serve.out

Remove the session's store tree out-of-band; the server notices absence —
not a transient read flap — and ends, bounded.

  $ rm -rf "$XDG_DATA_HOME/mentat/sessions/ghost"
  $ tries=0; while kill -0 "$GHOST_PID" 2>/dev/null && [ "$tries" -le 100 ]; do tries=$((tries+1)); sleep 0.1; done
  $ if kill -0 "$GHOST_PID" 2>/dev/null; then echo backstop-missed; kill -9 "$GHOST_PID"; fi
  $ wait_exit "$GHOST_PID"
  0
  $ test ! -e "$SOCK_BASE/ghost" && echo endpoint-removed
  endpoint-removed
