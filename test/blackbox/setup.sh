# Cram setup for the blackbox suite. Sourced before each test with
# cwd = $TESTCASE_ROOT; mentat, mentatd, mentat_cram, and fake_provider_server
# are all on PATH (via the test-cases/dune (binaries) stanza) and are invoked
# BARE — never `./…` — so they resolve regardless of the .t's depth.
#
# This sourcing establishes only a hermetic, host-independent *environment*. It
# deliberately does NOT trust the workspace or open the store — workspace
# posture is an explicit first command in each .t (use_trusted_workspace /
# use_untrusted_workspace / use_broken_store). Dropping the auto-trust is what
# makes the pre-store and untrusted classes (STORE-1, DOCTOR-2, TRUST-1, F7)
# writable at all.

export HOME="$PWD/home"
export XDG_CONFIG_HOME="$PWD/config"
export XDG_DATA_HOME="$PWD/data"
export XDG_STATE_HOME="$PWD/state"

# Drop any host Mentat/provider configuration so the suite is hermetic.
unset MENTAT_CONFIG MENTAT_CONFIG_HOME MENTAT_DATA_HOME MENTAT_STATE_HOME
unset MENTAT_MODEL MENTAT_MAX_STEPS MENTAT_REASONING
unset MENTAT_OPENAI_BASE_URL MENTAT_OPENAI_AUTH_BASE_URL
unset MENTAT_ANTHROPIC_BASE_URL MENTAT_OLLAMA_BASE_URL
unset OPENAI_API_KEY ANTHROPIC_API_KEY

# Deterministic, platform-independent posture: explicit unconfined execution so
# no fixture depends on a platform sandbox backend.
export MENTAT_SANDBOX_MODE=danger-full-access
export MENTAT_AUTO_TITLE=0

# The XDG roots exist, but data/mentat and sessions/ are left to the first store
# open so use_broken_store can plant a fault before anything touches the store.
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

# The shared normalization idiom: every human-surface golden ends `| censor`,
# so cram goldens and TUI frames speak one marker vocabulary.
censor () { mentat_cram censor "$@"; }

# Block until $1 exists and is non-empty.
wait_for_file () { mentat_cram wait-file "$1"; }

# --- workspace / store posture -------------------------------------------------

use_trusted_workspace () { mkdir -p .git; mentat trust . >/dev/null; }

use_untrusted_workspace () { mkdir -p .git; }

# Plant a store fault BEFORE any store-open so the lazy build_base create is the
# first thing to touch it and fails closed. STORE-1 (#14), DOCTOR-2 (#15).
# The unopenable variant is a self-referential symlink rather than a mode-000
# directory: mode bits do not constrain uid 0, so a chmod fault silently
# succeeds whenever the suite runs as root, whereas a symlink loop is refused
# for every identity on both Linux and macOS.
use_broken_store () {
  case "$1" in
    nondir)
      mkdir -p "$XDG_DATA_HOME/mentat"
      : > "$XDG_DATA_HOME/mentat/sessions" ;;             # a file where the dir belongs
    unopenable)
      rm -rf "$XDG_DATA_HOME/mentat"
      ln -s mentat "$XDG_DATA_HOME/mentat" ;;             # the open resolves onto itself
  esac
}

# --- model / editor family -----------------------------------------------------

# Pick the editor family by model identity, not a config override. String-replace
# needs a `mentat-test/edit` catalog entry whose editor family is string-replace
# and which the fake accepts.
use_model () {
  case "$1" in
    apply-patch)    export MENTAT_MODEL=openai/gpt-5.6-sol ;;   # apply_patch family
    string-replace) export MENTAT_MODEL=mentat-test/edit ;;  # edit_file/write_file family
  esac
}

# --- fake provider / issuer servers --------------------------------------------

# Launch the fake OpenAI Responses server on a scripted fixture; writes its port
# to $port_file and records requests under $capture. Serves the script's
# requests then exits; pair with wait_fake_server. Any further arguments are
# passed through to fake_provider_server (mode flags such as --unordered).
start_fake_server () {
  local script="$1" capture="${2:-capture}" port_file="${3:-server-port}"
  shift "$(( $# < 3 ? $# : 3 ))"
  mkdir -p "$capture"
  rm -f "$port_file"
  fake_provider_server --script "$script" --capture "$capture" \
    --port-file "$port_file" --accept-timeout 30 "$@" &
  MENTAT_FAKE_PROVIDER_PID=$!
  wait_for_file "$port_file"
}

# Start the fake server and point the openai provider at it (base URL + key +
# model), the common run/models path. Extra arguments pass through to the
# server.
start_fake_openai () {
  local script="$1" capture="${2:-capture}" port_file="${3:-openai-port}"
  shift "$(( $# < 3 ? $# : 3 ))"
  start_fake_server "$script" "$capture" "$port_file" "$@"
  export OPENAI_API_KEY=test-key
  export MENTAT_MODEL=openai/gpt-5.6-sol
  export MENTAT_OPENAI_BASE_URL="http://127.0.0.1:$(cat "$port_file")/v1"
}

# Start the fake server in unordered (content-matched) mode and point the
# openai provider at it: each arriving request consumes the first pending
# script item whose expectation it satisfies. The delegation path needs this —
# a parent session and its eagerly-driven children reach the provider in
# nondeterministic order.
start_fake_openai_unordered () {
  start_fake_openai "$1" "${2:-capture}" "${3:-openai-port}" --unordered
}

# Start the fake server as an OAuth issuer + readiness probe: /v1/models
# (200->ready, 401->blocked), /oauth/token, and --get for the browser callback.
# Wires the two base-URL seams the plain setup unsets.
start_fake_issuer () {
  local script="$1" capture="${2:-capture}" port_file="${3:-issuer-port}"
  start_fake_server "$script" "$capture" "$port_file"
  export MENTAT_OPENAI_AUTH_BASE_URL="http://127.0.0.1:$(cat "$port_file")/v1"
  export MENTAT_OPENAI_BASE_URL="http://127.0.0.1:$(cat "$port_file")/v1"
}

# Drive the OAuth loopback callback (the fake acts as the browser).
fake_browser_get () { fake_provider_server --get "$1"; }

# Same, but print the served callback page body instead of the status code.
fake_browser_body () { fake_provider_server --get-body "$1"; }

wait_fake_server () {
  wait "$MENTAT_FAKE_PROVIDER_PID"
  unset MENTAT_FAKE_PROVIDER_PID
}

# Register a fake Dune RPC endpoint for $PWD in the XDG registry (a hermetic
# stand-in for a running `dune build --watch`, no dune or compiler involved) and
# leave it listening, so the build-health notice producer observes the given
# scenario (failing|clean). Backgrounds it, waits until it has registered and is
# accepting, and records its pid for stop_fake_dune. It runs until stopped.
# All starters share this core; extra flags pass through.
start_fake_dune_with () {
  rm -f fake-dune-ready
  fake_dune_rpc_server --root "$PWD" "$@" --ready fake-dune-ready &
  MENTAT_FAKE_DUNE_PID=$!
  wait_for_file fake-dune-ready
}

start_fake_dune () {
  start_fake_dune_with --scenario "${1:-failing}"
}

# Like start_fake_dune, but dynamic: the server re-reads STATE_FILE
# (clean|failing|error2) on a short tick and answers its parked long-polls on a
# change, so a turn's own tool command can flip the build state mid-turn.
start_fake_dune_state () {
  start_fake_dune_with --state-file "$1"
}

# Watch-supervisor posture: dune.watch defaults to auto, under which a
# trusted fixture with a dune-project marker and an ambient dune on PATH
# would spawn a real `dune build --watch` mid-cram. Fixtures that engage the
# dune lane without wanting a spawn export MENTAT_DUNE_WATCH=observe as
# their first act; run/dune-own.t opts into auto per command against the
# fake dune shim.

# Like start_fake_dune_state, but serving at $PWD/_build/.rpc/dune — the
# pinned socket a real watch binds — so a supervisor probing that path finds
# an answering foreign server.
start_fake_dune_at_root () {
  start_fake_dune_with --state-file "$1" --socket-at-root
}

# Put the fake dune shim on PATH under the name `dune`: invoked as
# `dune build --root . --watch …` it records its argv in fake-dune-argv and
# serves the watch protocol per fake-dune-mode (see the fake's header).
use_fake_dune () {
  mkdir -p fake-bin
  ln -sf "$(command -v fake_dune_rpc_server)" fake-bin/dune
  export PATH="$PWD/fake-bin:$PATH"
}

stop_fake_dune () {
  kill "$MENTAT_FAKE_DUNE_PID" 2>/dev/null
  wait "$MENTAT_FAKE_DUNE_PID" 2>/dev/null
  unset MENTAT_FAKE_DUNE_PID
}

# --- two-process / signal choreography — bash in the .t, race-free -------------

# The fake writes capture/request-N.json AFTER the held process acquires the
# store lock and sends its request but BEFORE the delay_ms hold, so wait_captured
# is a happens-before edge: process 1 is provably in-turn before a signal lands.

# Start a run backgrounded against a delay_ms fixture; export its pid. Its own
# stdout/stderr are redirected to held-$id.out so the async "done"/"saved" lines do
# not pollute the cram golden of process 2 (only the second process's output is
# pinned; inspect held-$id.out explicitly if the held turn's output matters).
hold_run () {
  local id="$1" prompt="$2"
  mentat run start --id "$id" "$prompt" --cwd "$PWD" >"held-$id.out" 2>&1 &
  export MENTAT_HELD_PID=$!
}

# Block until the held process has reached the provider (lock held, in-turn).
wait_captured () { mentat_cram wait-file "capture/request-$1.json"; }

# Reap $1 and echo its exit code.
wait_exit () { wait "$1"; echo $?; }

# --- daemon (mentatd) ----------------------------------------------------------

# find_or_spawn resolves mentatd as a sibling of the running mentat binary.
# Under the cram harness that resolution is platform-dependent (Linux resolves
# the install-tree symlink into the build tree, where mentatd is not a
# sibling), so the daemon binary is named explicitly from PATH.
export MENTATD_BIN="$(command -v mentatd)"

# Start the per-user daemon foreground-backgrounded on its default per-store
# socket under /tmp (short, and keyed by the hermetic data home so it never
# collides with another test). MENTAT_DAEMON_MAX_IDLE is a leak backstop (A7): a
# daemon left behind by a failing test self-stops. Records its pid for stop_daemon
# and waits until its discovery file exists.
start_daemon () {
  export MENTAT_DAEMON_MAX_IDLE="${MENTAT_DAEMON_MAX_IDLE:-300}"
  mentatd >daemon-serve.out 2>&1 &
  MENTAT_DAEMON_PID=$!
  wait_for_file "$XDG_DATA_HOME/mentat/daemon/daemon.json"
}

# Stop the daemon: the graceful --stop, then a belt-and-suspenders kill of the
# recorded pid. A trap in the .t pairs with this so a failing test never leaks.
stop_daemon () {
  mentatd stop >/dev/null 2>&1 || true
  if [ -n "${MENTAT_DAEMON_PID:-}" ]; then
    kill "$MENTAT_DAEMON_PID" 2>/dev/null || true
    wait "$MENTAT_DAEMON_PID" 2>/dev/null || true
    unset MENTAT_DAEMON_PID
  fi
}
