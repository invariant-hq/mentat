Spawn resolution: how an attaching client finds the mentatd binary. The rest
of the suite always exercises the MENTATD_BIN override (setup.sh exports a
good one), so this pins the refusal arms and the default sibling resolution
the override otherwise hides.

  $ use_trusted_workspace
  $ export MENTAT_NOW=1753000000000
  $ trap stop_daemon EXIT

An override naming a directory is refused loudly, before anything spawns.

  $ MENTATD_BIN="$PWD" mentat session list --attach --cwd "$PWD" 2>&1 | censor
  mentat: MENTATD_BIN names $TESTCASE_ROOT, which is not a program
  [1]

An override naming a present but non-executable file is refused the same way —
exec permission is checked here, not discovered as a child exec failure the
poll would wait out.

  $ touch not-a-program
  $ MENTATD_BIN="$PWD/not-a-program" mentat session list --attach --cwd "$PWD" 2>&1 | censor
  mentat: MENTATD_BIN names $TESTCASE_ROOT/not-a-program, which is not a program
  [1]

With no override, the client resolves mentatd beside its own executable. A
lone mentat refuses loudly, naming the sibling it expected.

  $ mkdir bins
  $ cp "$(command -v mentat)" bins/
  $ MENTATD_BIN= bins/mentat session list --attach --cwd "$PWD" 2>&1 | censor
  mentat: the mentatd binary is missing: expected $TESTCASE_ROOT/bins/mentatd (every release installs it beside mentat); reinstall, or set MENTATD_BIN to run one from elsewhere
  [1]

With the sibling in place, the same invocation spawns it and attaches — the
path every real install takes.

  $ cp "$(command -v mentatd)" bins/
  $ mentat session create --id demo-session --title "resolved" --cwd "$PWD" >/dev/null
  $ MENTATD_BIN= bins/mentat session list --attach --cwd "$PWD" | censor
  ID            PHASE  AGE  TITLE
  demo-session  idle   0s   resolved
