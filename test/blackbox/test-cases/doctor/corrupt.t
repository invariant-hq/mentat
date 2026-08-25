DOCTOR-2 (#15) — corrupt-store structural check. A file where the sessions/
directory belongs (use_broken_store nondir) is a structural fault the storage check
must catch: doctor reports the storage check as a failure and list fails closed.
Because a WARN keeps exit 0 but a genuine storage FAIL is a runtime error, this is
the one doctor path that changes the exit code. The store never staged, so the
sessions scan cannot run and stays a WARN rather than double-counting the failure.
The toolchain probe is pinned to a missing [MENTAT_DUNE] for a host-independent line.

  $ use_broken_store nondir
  $ export MENTAT_DUNE=/nonexistent
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor -C . 2>&1 | censor
  [PASS] config: resolved ($TESTCASE_ROOT/config/mentat/config.json)
  [FAIL] storage: $TESTCASE_ROOT/data/mentat/sessions: not a directory
  [WARN] sessions: not scanned (storage unavailable)
  [WARN] trust: workspace not trusted; run `mentat trust .` to enable project config
  [WARN] auth: no connected provider; run `mentat auth login <provider>`
  [PASS] model: openai/gpt-5.6-sol
  [WARN] toolchain: dune not found on PATH or opam switch
  [WARN] parity: no dune to compare (see toolchain)
  [WARN] project: no dune-project (OCaml tooling inactive)
  [WARN] dune: lane off: workspace not trusted
  [WARN] lint: lint rides the dune lane: lane off: workspace not trusted
  [PASS] diagnostics: $TESTCASE_ROOT/state/mentat (0 log(s), 0 crash report(s))
  [1]
  $ MENTAT_MODEL=openai/gpt-5.6-sol mentat doctor -C . >/dev/null 2>&1; echo $?
  1
