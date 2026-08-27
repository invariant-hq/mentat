The resident-service verbs, driven only through their no-touch surfaces:
--print renders the launchd unit without writing anything, and the refusal
paths fire before any launchctl call — this cram must never load a real
service. The pinned golden carries the crash-story contract explicitly:
AbandonProcessGroup keeps run children alive across a stop or crash of the
daemon, which adopts them at its next boot.

  $ mentatd install --print | sed -E 's#<string>/[^<]*mentatd</string>#<string>MENTATD</string>#'
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <!-- Written by `mentatd install`; `mentatd uninstall` removes it, and the
       next install overwrites it. AbandonProcessGroup is load-bearing: the
       daemon's run children detach into their own sessions and must outlive
       it, so stopping or restarting this job may signal only the daemon
       itself — it adopts the survivors when it next boots. Without the key,
       launchd would take mid-turn runs down with the job. -->
  <plist version="1.0">
  <dict>
    <key>Label</key>
    <string>dev.invarianthq.mentatd</string>
    <key>ProgramArguments</key>
    <array>
      <string>MENTATD</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
      <key>SuccessfulExit</key>
      <false/>
    </dict>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$TESTCASE_ROOT/data/mentat/daemon/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$TESTCASE_ROOT/data/mentat/daemon/daemon.log</string>
  </dict>
  </plist>

The daemon's serve flags bake into the exec line: --ingress-port,
--github-base-url, --charter-git-base, --web, and --web-port render as
further ProgramArguments entries, so the resident daemon starts with them
at every boot — --web is the only way a service-managed daemon serves the
charters dashboard, since only one daemon claims a store.

  $ mentatd install --print --ingress-port 8080 --github-base-url https://ghe.example.test/api/v3 --charter-git-base https://ghe.example.test --web --web-port 8081 | sed -n '/<array>/,/<\/array>/p' | sed -E 's#<string>/[^<]*mentatd</string>#<string>MENTATD</string>#'
    <array>
      <string>MENTATD</string>
      <string>--ingress-port=8080</string>
      <string>--github-base-url=https://ghe.example.test/api/v3</string>
      <string>--charter-git-base=https://ghe.example.test</string>
      <string>--web</string>
      <string>--web-port=8081</string>
    </array>

A port outside 0-65535 is a usage error at the flag, on both surfaces —
never a listen-time raise, never a permanently failing unit.

  $ mentatd install --print --ingress-port=65536 2>&1 | grep -c 'between 0 and 65535'
  1
  [124]
  $ mentatd --ingress-port=-1 2>&1 | grep -c 'between 0 and 65535'
  1
  [124]

--print touched nothing: no LaunchAgents directory, no daemon directory.

  $ test -e "$HOME/Library" || echo untouched
  untouched
  $ test -e "$XDG_DATA_HOME/mentat" || echo untouched
  untouched

Uninstalling an absent unit is a clean, success-shaped no-op with a note.

  $ mentatd uninstall
  nothing to uninstall: $TESTCASE_ROOT/home/Library/LaunchAgents/dev.invarianthq.mentatd.plist does not exist

A file at the unit path that mentatd install did not write is named and
refused — by both verbs, before anything touches the service manager.

  $ mkdir -p "$HOME/Library/LaunchAgents"
  $ echo 'hand-written' > "$HOME/Library/LaunchAgents/dev.invarianthq.mentatd.plist"
  $ mentatd install
  mentat: refusing to overwrite $TESTCASE_ROOT/home/Library/LaunchAgents/dev.invarianthq.mentatd.plist: it is not a unit `mentatd install` wrote; move it aside first
  [1]
  $ mentatd uninstall
  mentat: refusing to remove $TESTCASE_ROOT/home/Library/LaunchAgents/dev.invarianthq.mentatd.plist: it is not a unit `mentatd install` wrote; remove it yourself if it is stale
  [1]
  $ cat "$HOME/Library/LaunchAgents/dev.invarianthq.mentatd.plist"
  hand-written
