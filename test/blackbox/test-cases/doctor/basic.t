DOCTOR-3 — the healthy trusted doctor. next's doctor aggregates nine local health
checks (config, storage, sessions, trust, auth, model, toolchain, project,
diagnostics) without
contacting a provider. A fresh trusted workspace with no credential is healthy: the
missing credential is a [WARN], which does NOT change the exit code — doctor exits 0.
The OCaml toolchain probe is pinned to a missing [MENTAT_DUNE] so the "not found"
branch is host-independent; the found branch lives in tooling.t.

  $ use_trusted_workspace
  $ export MENTAT_DUNE=/nonexistent
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor | censor
  [PASS] config: resolved ($TESTCASE_ROOT/config/mentat/config.json)
  [PASS] storage: session store at $TESTCASE_ROOT/data/mentat
  [PASS] sessions: 0 stored, 0 corrupt
  [PASS] trust: workspace trusted
  [WARN] auth: no connected provider; run `mentat auth login <provider>`
  [PASS] model: openai/gpt-5.6-sol
  [WARN] toolchain: dune not found on PATH or opam switch
  [WARN] parity: no dune to compare (see toolchain)
  [WARN] project: no dune-project (OCaml tooling inactive)
  [WARN] dune: no dune-project (OCaml tooling inactive)
  [WARN] lint: lint rides the dune lane: no dune-project (OCaml tooling inactive)
  [PASS] diagnostics: $TESTCASE_ROOT/state/mentat (0 log(s), 0 crash report(s))

The --json envelope carries the same nine checks as one deterministic line, with the
warn level surfaced structurally — strictly more than the old `grep -o '"type"'`.

  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor --json | censor
  {"schema_version":1,"type":"doctor","checks":[{"name":"config","level":"pass","detail":"resolved ($TESTCASE_ROOT/config/mentat/config.json)"},{"name":"storage","level":"pass","detail":"session store at $TESTCASE_ROOT/data/mentat"},{"name":"sessions","level":"pass","detail":"0 stored, 0 corrupt"},{"name":"trust","level":"pass","detail":"workspace trusted"},{"name":"auth","level":"warn","detail":"no connected provider; run `mentat auth login <provider>`"},{"name":"model","level":"pass","detail":"openai/gpt-5.6-sol"},{"name":"toolchain","level":"warn","detail":"dune not found on PATH or opam switch"},{"name":"parity","level":"warn","detail":"no dune to compare (see toolchain)"},{"name":"project","level":"warn","detail":"no dune-project (OCaml tooling inactive)"},{"name":"dune","level":"warn","detail":"no dune-project (OCaml tooling inactive)"},{"name":"lint","level":"warn","detail":"lint rides the dune lane: no dune-project (OCaml tooling inactive)"},{"name":"diagnostics","level":"pass","detail":"$TESTCASE_ROOT/state/mentat (0 log(s), 0 crash report(s))"}]}

A present credential flips the auth check to [PASS] with the connected count; the run
still never contacts the provider.

  $ OPENAI_API_KEY=test-key MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor | censor
  [PASS] config: resolved ($TESTCASE_ROOT/config/mentat/config.json)
  [PASS] storage: session store at $TESTCASE_ROOT/data/mentat
  [PASS] sessions: 0 stored, 0 corrupt
  [PASS] trust: workspace trusted
  [PASS] auth: 1 connected provider(s)
  [PASS] model: openai/gpt-5.6-sol
  [WARN] toolchain: dune not found on PATH or opam switch
  [WARN] parity: no dune to compare (see toolchain)
  [WARN] project: no dune-project (OCaml tooling inactive)
  [WARN] dune: no dune-project (OCaml tooling inactive)
  [WARN] lint: lint rides the dune lane: no dune-project (OCaml tooling inactive)
  [PASS] diagnostics: $TESTCASE_ROOT/state/mentat (0 log(s), 0 crash report(s))

A provider-local credential-resolution failure remains a separate failed check
without erasing a healthy connected sibling.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ printf '{"version":1,"credentials":{"anthropic":{"default":{"kind":"bearer","token":"wrong-kind"}}}}' > "$XDG_CONFIG_HOME/mentat/auth.json"
  $ chmod 600 "$XDG_CONFIG_HOME/mentat/auth.json"
  $ OPENAI_API_KEY=test-key MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor >provider-error.out; echo $?
  1
  $ grep '^\[PASS\] auth: 1 connected provider(s)' provider-error.out
  [PASS] auth: 1 connected provider(s)
  $ grep -o '^\[FAIL\] auth:anthropic: credential .* kind bearer' provider-error.out
  [FAIL] auth:anthropic: credential from store(default) has kind bearer
  $ rm "$XDG_CONFIG_HOME/mentat/auth.json"

An untrusted workspace turns the trust check to [WARN] with the enabling hint; it too
keeps the exit code at 0 (a warning is not a failure).

  $ mkdir -p untrusted/.git
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor -C untrusted | censor
  [PASS] config: resolved ($TESTCASE_ROOT/config/mentat/config.json)
  [PASS] storage: session store at $TESTCASE_ROOT/data/mentat
  [PASS] sessions: 0 stored, 0 corrupt
  [WARN] trust: workspace not trusted; run `mentat trust .` to enable project config
  [WARN] auth: no connected provider; run `mentat auth login <provider>`
  [PASS] model: openai/gpt-5.6-sol
  [WARN] toolchain: dune not found on PATH or opam switch
  [WARN] parity: no dune to compare (see toolchain)
  [WARN] project: no dune-project (OCaml tooling inactive)
  [WARN] dune: no dune-project (OCaml tooling inactive)
  [WARN] lint: lint rides the dune lane: no dune-project (OCaml tooling inactive)
  [PASS] diagnostics: $TESTCASE_ROOT/state/mentat (0 log(s), 0 crash report(s))
