Daemon lifecycle: one process serves the store; a session
created offline is visible through it via --attach; the claim collapses racing
starts; stop is idempotent. The socket is the default per-store /tmp path
(short, keyed by the hermetic data home); its perms are pinned by the unit
discovery tests, so this covers the real-process path the unit tests cannot.

  $ use_trusted_workspace
  $ export MENTAT_NOW=1753000000000
  $ trap stop_daemon EXIT

The daemon starts and advertises itself through its private discovery file.

  $ start_daemon

A second daemon for the same store refuses at the claim, exit 1 — this is what
collapses racing spawns to one winner.

  $ mentatd 2>&1 | censor
  mentat: a mentat daemon is already running for this store (see daemon.json)
  [1]

A session created offline is durable at commit, so it is visible through the
running daemon over --attach (a real registry boot + wire round-trip).

  $ mentat session create --id demo-session --title "from offline" --cwd "$PWD" >/dev/null
  $ mentat session list --attach --cwd "$PWD" | censor
  ID            PHASE  AGE  TITLE
  demo-session  idle   0s   from offline

Stopping the daemon removes the discovery file; a second stop is a clean,
success-shaped no-op (idempotent stop).

  $ mentatd stop
  $ test -e "$XDG_DATA_HOME/mentat/daemon/daemon.json" && echo present || echo gone
  gone
  $ mentatd stop

The old flag spelling survives one release as a deprecated alias.

  $ mentatd --stop
  mentatd: deprecated option --stop: use 'mentatd stop' instead
