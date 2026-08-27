DOCTOR toolchain + project checks, present branches. The toolchain probe resolves
[dune] through the [Mentat_ocaml_toolchain] ladder; pointing the [MENTAT_DUNE]
override at an executable stub makes the resolved path host-independent and exercises
the found branch. A [dune-project] marker at the root flips the project check to
present. Neither changes the exit code — a workspace without OCaml tooling is a
warning, not a failure. (The live dune build-health verdict is deliberately not read
by doctor; it rides the workspace notice channel.)

The stub lives in a directory placed at the front of PATH and the override
names that same file, so the parity row's two resolutions — mentat's ladder
and the child PATH a confined command searches — agree on one binary and the
row is a host-independent pass. (The suite's own dune is further down the
ambient PATH; without the front placement, parity would truthfully warn that
commands resolve a different dune than the override.)

  $ use_trusted_workspace
  $ mkdir stub-bin
  $ printf '#!/bin/sh\ntrue\n' > stub-bin/dune
  $ chmod +x stub-bin/dune
  $ printf '#!/bin/sh\ntrue\n' > stub-bin/litany
  $ chmod +x stub-bin/litany
  $ export PATH="$PWD/stub-bin:$PATH"
  $ export MENTAT_DUNE="$PWD/stub-bin/dune"
  $ touch dune-project
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor | censor
  [PASS] config: resolved ($TESTCASE_ROOT/config/mentat/config.json)
  [PASS] storage: session store at $TESTCASE_ROOT/data/mentat
  [PASS] sessions: 0 stored, 0 corrupt
  [PASS] trust: workspace trusted
  [WARN] auth: no connected provider; run `mentat auth login <provider>`
  [PASS] model: openai/gpt-5.6-sol
  [PASS] toolchain: dune at $TESTCASE_ROOT/stub-bin/dune (via MENTAT_* override)
  [PASS] parity: commands resolve the same dune ($TESTCASE_ROOT/stub-bin/dune)
  [PASS] project: dune project
  [PASS] dune: auto — spawns and supervises `dune build --watch @check`
  [PASS] lint: litany check --no-build --trust-build — resolves via PATH
  [PASS] diagnostics: $TESTCASE_ROOT/state/mentat (0 log(s), 0 crash report(s))
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor >/dev/null 2>&1; echo $?
  0

The toolchain override is authoritative: an override set but not executable is "not
found" (it never falls through to PATH), so the found path is exactly the override.

  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor --json | mentat_cram json '.checks[6].detail' | censor
  dune at $TESTCASE_ROOT/stub-bin/dune (via MENTAT_* override)
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor --json | mentat_cram json '.checks[8].detail'
  dune project

The dune row mirrors every rung of the lane's gate, not only the knob:
workspace.tooling=off switches the lane off whatever the marker says, and a
read-only sandbox demotes auto to observe.

  $ MENTAT_WORKSPACE_TOOLING=off MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor | censor | grep -E 'dune:|lint:'
  [WARN] dune: lane off: workspace.tooling = off
  [WARN] lint: lint rides the dune lane: lane off: workspace.tooling = off
  $ MENTAT_SANDBOX_MODE=read-only MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor | censor | grep -E 'dune:'
  [PASS] dune: observe — auto demoted by sandbox.mode = read-only

The lint row walks the resolver's own rungs. A command reachable nowhere is
a skipped-settles warning, never a lane death; the same command becomes the
lock universe's built binary the moment the package store holds it. The
probe name is unique to this fixture so no ambient linter can answer for
it.

  $ rm stub-bin/litany
  $ mentat config set dune.lint_command '["lintcheck2", "run"]' >/dev/null
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor | censor | grep -E 'lint:'
  [WARN] lint: lintcheck2 is not reachable on PATH or in the lock universe; green settles are skipped until it appears
  $ mkdir -p _build/_private/default/.pkg/lintcheck2.1.0/target/bin
  $ printf '#!/bin/sh\ntrue\n' > _build/_private/default/.pkg/lintcheck2.1.0/target/bin/lintcheck2
  $ chmod +x _build/_private/default/.pkg/lintcheck2.1.0/target/bin/lintcheck2
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor | censor | grep -E 'lint:'
  [PASS] lint: lintcheck2 run — runs the lock universe's built binary
