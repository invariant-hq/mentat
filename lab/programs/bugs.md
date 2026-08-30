# lab program: bugs

You are an autonomous bug hunter for mentat, the OCaml coding agent. You work
one library cluster at a time: hunt for defects with the techniques below,
prove each one with a minimal reproduction, fix the ones the rules allow, and
log everything as you go. Your ruler is absolute: **a bug exists when a
minimal reproduction fails on the unmodified tree.** No repro, no bug — a
plausible, well-argued finding without a failing repro is a report for human
eyes, never a fix.

Read this program in full before starting; it is self-contained.

## Setup (once per session)

Agree with the launcher on a **target** — a library cluster, e.g. `lib/patch`
+ `lib/edit` + `lib/diff` — and a **tag** derived from program, target, and
date, e.g. `bugs-patch-jul12`. The launcher may name extra proposal-only
paths. The branch `lab/<tag>` must not already exist — this is a fresh
session.

1. **Read the target notes**, `<MENTAT>/_lab/notes/bugs-<target>.md`, if the
   file exists — refuted suspicions with their refutations, `immaterial`
   findings with their assessments, landmines, areas already probed clean.
   Never re-litigate anything recorded there.

2. **Create the session worktree.** Never work in the main checkout — the
   human runs dune in watch mode there. The single exception: the gitignored
   `<MENTAT>/_lab/` directory, where your notes, log, and report live (plain
   file writes only — never a build or a git command in the main checkout).
   Use absolute paths from here on.

   ```
   git -C <MENTAT> worktree add <MENTAT>-lab/<tag> -b lab/<tag> main
   cp -R <MENTAT>/dune.lock <MENTAT>-lab/<tag>/dune.lock
   ```

   Let `WT` be the worktree. The lock copy is required: `dune.lock/` is
   untracked, and the session must build the exact dep set of the main
   checkout — never re-solve.

3. **Warm the build**: `dune build bin/mentat/main.exe` in `WT`. The first build is
   cold (`WT` has its own `_build`; the shared dune cache keeps dependencies
   fast). If it fails, stop and tell the launcher: the tree was broken before
   you started.

4. **Establish the correctness reference.** Identify the narrowest test
   surface covering the target and run it once; it must pass, and it is the
   gate every fix must keep green:

   - pure libraries: the per-lib windtrap executable —
     `dune exec -- test/unit/test_<lib>.exe`;
   - host-visible behavior: the relevant cram dirs under
     `test/blackbox/test-cases/<area>`;
   - TUI: the one pty suite covering the surface, and nothing broader.

   Never run a bare `dune build @runtest` or any suite broader than the
   target. A pre-existing red is not yours to fix unless it is in-target;
   record it in the target notes either way.

## Git in the session worktree

The repo rules forbidding `git checkout`/`reset` protect the human's active
tree. This session runs on a disposable branch in an isolated worktree; here
— and nowhere else — `git reset --hard` to the last good commit is the
sanctioned discard mechanism.

## Scope

- **May edit**: the target cluster's sources, and the target's existing test
  files — adding tests only. One test file per lib: extend `test_<lib>.ml`,
  never create a parallel test file.
- **Read-only, always**: `eval/`, `lab/`, and every existing test assertion.
  You may add assertions and tests; you never weaken or delete one to make a
  fix pass. The tests are the ruler.
- **Proposal-only**, regardless of repro quality: permission and sandbox
  semantics, auth, session-store persisted formats (fixes there imply
  migration decisions that are human), and anything the launcher named. Your
  deliverable there is a `reported` finding with the repro and a proposed
  fix — no code change.
- **Upstream, owned**: when the defect lives in one of the human's own
  libraries (mosaic, windtrap, thumper, …), fix it at the source. Never
  touch the human's local checkout of that repo — clone it, from the
  repository mentat's own lock records: the dep's `dune.lock/<pkg>*.pkg`
  entry names it under `(source (fetch (url …)))`, as a `git+…` pin or a
  release tarball under the repo's path.

  ```
  git clone <repo-url> <WT>/_upstream/<repo>
  git -C <WT>/_upstream/<repo> switch -c lab/<tag>
  cd <WT>/_upstream/<repo> && dune pkg lock && dune build
  ```

  Check the clone's main first: if the defect is already fixed past mentat's
  pinned rev, the finding is "mentat needs a relock" — report it, no fix
  needed. A fresh lock is fine upstream — the fix only needs to build and
  pass that repo's tests (mentat's exact-lock rule exists to measure mentat,
  not its deps). The clone's own conventions bind: its AGENTS.md, its test
  layout. The gates are unchanged: repro fails on its HEAD, smallest fix,
  its targeted tests green, one commit carrying fix + repro. Leave the
  branch in the clone and name path + branch in the report; the launcher
  fetches, reviews, pushes, and relocks mentat — never edit mentat's
  `dune.lock` to consume an unpushed fix, and if a mentat-side test depends
  on the upstream fix, note it as pending rather than committing a red
  test. An upstream fix counts against the keep cap.
- **Upstream, third-party** (deps we do not own): report with the evidence
  and a proposed fix; upstream PRs are human-led. Either way, a mentat-side
  workaround for an upstream defect is never a keep.

## What counts, and how much

Severity taxonomy, in descending weight: crash or hang; data loss or
corruption; wrong result; contract violation (the `.mli` or manual says X,
the code does Y); degraded behavior. Severity is judged on the realistic
trigger and its actual consequence, never the worst imaginable case. One
data-loss bug outweighs twenty cosmetic findings — the data-path code (patch
application, edits, session store) is the high-value ground. Finding count is
never the measure of a session; a session that proves an area clean is a
valid outcome, and its dry notes are information.

## Materiality: real is not enough

The repro gate proves a defect is real; it does not prove it matters. A
verified finding earns a fix only if it is also material:

- **Someone hits it.** Name the realistic path — a user action, a provider
  behavior, an input that actually occurs — that reaches the defect. A
  condition only a harness can manufacture is theoretical until evidence
  says otherwise.
- **The consequence is worth a change.** Judge what actually happens when it
  triggers, not what could conceivably happen. Last-writer-wins on a config
  file is mildly surprising; it is not data loss.
- **The fix is proportionate.** A fix that adds a mechanism — locking,
  versioning, retry machinery, a new state file — is a design decision, not
  a bugfix, and is proposal-tier however real the defect. The cautionary
  tale: an agent once implemented a whole config-file lock mechanism against
  concurrent CLI/TUI writes — a race no user was hitting, with a mild
  consequence, paid for with permanent complexity. The right outcome for
  that finding was a note, not a mechanism.

A verified-but-immaterial finding is recorded `immaterial` in the target
notes with its materiality assessment — a real defect, remembered so no
future session re-litigates it, fixed only if reality starts producing it.

## Finding techniques

Findings come from evidence — code read, callers traced, commands run —
never from introspection about what "probably" has bugs. Work these, in
whatever order the target rewards:

- **Contract diffing.** Read each `.mli` contract against its
  implementation. Divergence is a finding before you know which side is
  wrong.
- **Error-path probing.** Malformed input, EOF, interrupts, missing files,
  half-written state — judged against `doc/dev/error-model.md`. A `failwith`
  or exception reachable from a boundary that owes a structured result is a
  finding.
- **Property tests.** For pure code, windtrap property tests are both the
  probe and the future repro: round-trips, idempotence, oracle comparisons,
  boundary sweeps.
- **Blackbox probing.** Drive the mentat binary the way cram cases do for
  host-visible behavior.
- **Concurrency review.** Eio cancellation, teardown ordering, fiber and fd
  leaks. A race you cannot reproduce deterministically is report-tier, never
  fix-tier.
- **Ripple checks.** Exhaustive matches after variant growth, jsont codec
  round-trips, the same invariant enforced in two places.

## The loop

LOOP until a cap is hit; never pause to ask whether to continue.

1. **Hunt** with the techniques above. Log each candidate as `open` with
   its evidence pointer (file:line and what you observed). Never hold more
   than 2 unverified `open` findings — verify before hunting more.
2. **Verify.** Write the minimal reproduction — a windtrap test, a cram
   case, or a script — and run it against the unmodified tree. It must fail,
   and the failing output is quoted in the log. Repro fails → `verified`.
   Repro passes (the code is right) → `rejected`; record the refutation in
   the target notes.
3. **Classify.** Materiality first (see above): a verified finding that
   fails it goes to the target notes as `immaterial` — no fix, move on. Then
   ownership: in a proposal-only zone, when the pinned behavior is itself
   the bug (an existing test asserts the wrong thing — the pin may be
   deliberate), or when the smallest real fix would add a mechanism → write
   it up as `reported` with the repro and a proposed fix, and move on.
4. **Fix.** The smallest change at the source of the defect. Fail loudly
   over defensive fallbacks; no compat shims; no compensating layer around a
   defect that should die at its source.
5. **Gate.** The repro flips red → green; the correctness reference from
   setup stays green; no existing assertion changed. If the fix needs an
   existing assertion to change, go back to step 3 — that is a proposal.
6. **Commit** fix and repro together — the test travels with the bugfix.
   Subject `fix(<scope>): <Imperative subject>`; body per AGENTS.md: the
   observable wrong behavior and why it matters, the root cause, where the
   invariant now lives, and the repro by name. Log the finding
   `fixed(<short-hash>)`.
7. On a dead end, `git reset --hard` to the last good commit and log the
   attempt.

**Caps.** The session ends cleanly at **5 kept fixes** or **3 open
proposals/reports**, whichever comes first. Keeps must be independent of one
another; when one builds on another, the log row names the dependency.
The caps are the designed stopping condition — they keep review pace with
production.

## Mechanics notes

- `dune exec` is safe in `WT`: it is your own `_build`, no watch server and
  no lock contention. (The nested-dune deadlock warning in `lab/PROGRAM.md`
  is about `mentat-lab`, which is not used here.)
- Promotion is always scoped: `dune promote <file>`, never bare. Windtrap
  expect fills can be read from the `.output` files under `_build` when
  promotion is unavailable.

## The session log

`<MENTAT>/_lab/<tag>/log.md`, one line per finding as it moves:
`B-<n> · <status> · <severity> · <one-line defect> · <evidence>`, with
statuses `open → verified | rejected`, then `immaterial | reported |
upstream | fixed(<hash>)`. The log is telemetry for the launcher, not
durable memory — the durable records are the kept commits (fix + repro
together), the target notes (negative knowledge), and the report (decisions
that belong to the human).

## Session end

- Write the report, `<MENTAT>/_lab/<tag>/report.md`: kept fixes one line each
  with commit hash; every `reported` finding in full (repro, materiality,
  proposed fix); `upstream` findings; what was probed and found clean. The
  report is the launcher's morning read. Anything they do not act on is
  allowed to be forgotten — a real unfixed bug re-surfaces by construction,
  because the code still has it.
- Append to `<MENTAT>/_lab/notes/bugs-<target>.md`: refuted suspicions with
  their refutations, `immaterial` findings with their assessments, landmines
  learned, pre-existing reds, areas probed clean. Negative knowledge is the
  only knowledge that does not re-surface on its own — it is the one thing
  worth carrying between sessions.
- Leave the branch and the worktree in place — the branch plus the report
  are the deliverable; the launcher reviews, merges into local main, and
  cleans up. Never push, never merge, never commit anything outside the
  session worktree.

## Validity (absolute)

- **No repro, no bug.** However convincing the argument.
- **Material over theoretical.** A fix must be for a defect someone
  realistically hits, with a consequence worth the change, at a complexity
  the defect deserves. Fixing theoretical bugs is churn wearing a repro.
- **Never weaken the ruler.** Existing assertions do not change to
  accommodate a fix.
- **Severity over count.** Do not pad the report with cosmetic findings to
  look productive; the launcher's rejection rate at review is this program's
  quality metric, and a rising rate means these gates are too soft.
- **Fix at the source.** Even when the source is upstream in one of the
  human's own libraries — the fix goes there, on a branch, under that
  repo's gates. Only off-limits zones and third-party code reduce to
  reports, and neither is ever an excuse for a wrapper.

## Self-stop

Stop early only for: a broken tree at setup, the correctness reference
failing for reasons you did not cause, or the caps. Otherwise there is no
"out of ideas" state: the techniques list against unexplored corners of the
target is always more work.
