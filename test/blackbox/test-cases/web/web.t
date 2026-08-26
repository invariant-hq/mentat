Browser frontend mounting: `mentatd --web` binds a
loopback listener that serves the html-over-the-wire frontend behind the daemon's
one shared network edge — the single-use-token → cookie exchange, the
unconditional Origin/Host allowlist, and the strict CSP. This drives the real
daemon and the real mentat.web over HTTP, the path the unit edge tests and the
frozen render snapshots cannot reach end to end.

  $ use_trusted_workspace
  $ export MENTAT_NOW=1753000000000
  $ export MENTAT_DAEMON_MAX_IDLE=300
  $ trap stop_daemon EXIT

The daemon starts with the browser frontend and prints its URL — the bootstrap
token in the query — to standard output, on an ephemeral loopback port.

  $ mentatd --web >web.out 2>&1 &
  $ MENTAT_DAEMON_PID=$!
  $ wait_for_file "$XDG_DATA_HOME/mentat/daemon/daemon.json"
  $ for _ in $(seq 1 100); do grep -q 'mentat web: open' web.out && break; sleep 0.1; done
  $ URL=$(sed -n 's/^mentat web: open //p' web.out)
  $ PORT=$(printf '%s' "$URL" | sed -E 's#.*127\.0\.0\.1:([0-9]+)/.*#\1#')
  $ BASE="http://127.0.0.1:$PORT"

/health is pre-auth and content-free: find-or-spawn reaches it before holding any
credential, so it leaks nothing.

  $ curl -sS "$BASE/health"; echo
  ok

An unauthenticated request for the app is refused — the cookie is the credential,
not mere reachability of the loopback port.

  $ curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/"
  401

The bootstrap token is exchanged for a SameSite=Strict, HttpOnly session cookie,
and the redirect drops the token from the address bar.

  $ curl -sS -c jar -D hdr -o /dev/null -w '%{http_code}\n' "$URL"
  303
  $ grep -qi 'set-cookie: mentat_session=' hdr && echo cookie-set
  cookie-set
  $ grep -qi 'httponly' hdr && grep -qi 'samesite=strict' hdr && echo cookie-hardened
  cookie-hardened
  $ LOC=$(grep -i '^location:' hdr | tr -d '\r' | awk '{print $2}')
  $ [ "$LOC" = "/" ] && echo token-dropped
  token-dropped

The cookie authenticates the real session index, and every HTML response carries
the strict CSP set at the shared edge.

  $ curl -sS -b jar -D hdr2 -o /dev/null -w '%{http_code}\n' "$BASE/"
  200
  $ grep -qi "content-security-policy: default-src 'none'" hdr2 && echo csp-strict
  csp-strict
  $ grep -qi "frame-ancestors 'none'" hdr2 && echo no-frame
  no-frame

The exchange consumed the token and rotated: replaying the same URL — a leaked
browser-history entry — is refused, while the daemon republished a freshly
minted successor into daemon.json (the 0600 trust root), so the discovery file
always names a live entry URL and cookie loss never locks the browser out
(consume-and-rotate).

  $ curl -sS -o /dev/null -w '%{http_code}\n' "$URL"
  401
  $ URL2=$(grep -o '"web_url":"[^"]*"' "$XDG_DATA_HOME/mentat/daemon/daemon.json" | cut -d'"' -f4)
  $ [ -n "$URL2" ] && [ "$URL2" != "$URL" ] && echo rotated
  rotated
  $ curl -sS -c jar2 -o /dev/null -w '%{http_code}\n' "$URL2"
  303
  $ curl -sS -b jar2 -o /dev/null -w '%{http_code}\n' "$BASE/"
  200

The first browser's cookie survives the rotation — each entry mints its own
cookie; rotation replaces only the URL token.

  $ curl -sS -b jar -o /dev/null -w '%{http_code}\n' "$BASE/"
  200

A forged cross-origin POST — the CSRF and DNS-rebinding case — is refused before
it can reach a client field, even carrying a valid cookie: a single forged
command must not drive a shell-executing session.

  $ curl -sS -b jar -H 'Origin: http://evil.example.com' -X POST -o /dev/null -w '%{http_code}\n' "$BASE/sessions"
  403

The daemon holds a live web-pinned instance, so a {e single} signal must settle
it durable-first and exit: teardown resolves every booted instance's release
(the boot fiber's one shutdown path) rather than calling shutdown around it —
the first-signal wedge that needed a second Ctrl+C. [serve.t] owns the
[mentatd --stop] coverage; this pins the raw one-signal contract.

  $ kill -TERM $MENTAT_DAEMON_PID
  $ for _ in $(seq 1 100); do kill -0 $MENTAT_DAEMON_PID 2>/dev/null || break; sleep 0.1; done
  $ kill -0 $MENTAT_DAEMON_PID 2>/dev/null && echo alive || echo stopped
  stopped
  $ test -e "$XDG_DATA_HOME/mentat/daemon/daemon.json" && echo present || echo gone
  gone
