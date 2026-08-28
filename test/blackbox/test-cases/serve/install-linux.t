The resident-service verbs, driven only through their no-touch surfaces:
--print renders the systemd user unit without writing anything, and the
refusal paths fire before any systemctl call — this cram must never enable a
real service. The pinned golden carries the crash-story contract explicitly:
KillMode=process keeps run children alive across a stop or restart of the
daemon; the reconcile pass settles any orphaned routine run at its next boot.

  $ mentatd install --print | sed -E 's#^ExecStart=".*"$#ExecStart="MENTATD"#'
  # Written by `mentatd install`; `mentatd uninstall` removes it, and the
  # next install overwrites it. KillMode=process is load-bearing: the daemon's
  # run children detach into their own sessions and must outlive it, so
  # stopping or restarting this unit may signal only the daemon itself — it
  # survivors account for themselves; reconcile settles orphaned routine runs. The default control-group kill
  # would take mid-turn runs down with the unit. The restart pacing is
  # load-bearing too: a daemon spawned outside the service holds the per-user
  # claim and this unit's daemon then exits nonzero, so the manager must retry
  # until the claim frees — the default burst limit would park the unit failed
  # after five fast exits instead.
  
  [Unit]
  Description=mentat daemon
  StartLimitIntervalSec=0
  
  [Service]
  ExecStart="MENTATD"
  KillMode=process
  Restart=on-failure
  RestartSec=10
  StandardOutput=append:$TESTCASE_ROOT/data/mentat/daemon/daemon.log
  StandardError=append:$TESTCASE_ROOT/data/mentat/daemon/daemon.log
  
  [Install]
  WantedBy=default.target

The daemon's serve flags bake into the exec line: --ingress-port,
--github-base-url, --routine-git-base, --web, and --web-port ride
ExecStart as further quoted arguments, so the resident daemon starts with
them at every boot — --web is the only way a service-managed daemon serves
the routines dashboard, since only one daemon claims a store.

  $ mentatd install --print --ingress-port 8080 --github-base-url https://ghe.example.test/api/v3 --routine-git-base https://ghe.example.test --web --web-port 8081 | grep '^ExecStart=' | sed -E 's#^ExecStart="[^"]*"#ExecStart="MENTATD"#'
  ExecStart="MENTATD" "--ingress-port=8080" "--github-base-url=https://ghe.example.test/api/v3" "--routine-git-base=https://ghe.example.test" "--web" "--web-port=8081"

--print touched nothing: no unit directory, no daemon directory.

  $ test -e "$XDG_CONFIG_HOME/systemd" || echo untouched
  untouched
  $ test -e "$XDG_DATA_HOME/mentat" || echo untouched
  untouched

Uninstalling an absent unit is a clean, success-shaped no-op with a note.

  $ mentatd uninstall
  nothing to uninstall: $TESTCASE_ROOT/config/systemd/user/mentatd.service does not exist

A file at the unit path that mentatd install did not write is named and
refused — by both verbs, before anything touches the service manager.

  $ mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  $ echo 'hand-written' > "$XDG_CONFIG_HOME/systemd/user/mentatd.service"
  $ mentatd install
  mentat: refusing to overwrite $TESTCASE_ROOT/config/systemd/user/mentatd.service: it is not a unit `mentatd install` wrote; move it aside first
  [1]
  $ mentatd uninstall
  mentat: refusing to remove $TESTCASE_ROOT/config/systemd/user/mentatd.service: it is not a unit `mentatd install` wrote; remove it yourself if it is stale
  [1]
  $ cat "$XDG_CONFIG_HOME/systemd/user/mentatd.service"
  hand-written
