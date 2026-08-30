# Evaluation instrument and research lab

Mentat measures itself with two layered tools. The **eval instrument** (`eval/`)
is a product-quality, agent-agnostic regression suite: it materializes a task
workspace, drives a coding agent headlessly, grades the result, captures the
whole session, and turns that capture into metrics and structured
observations. The **research lab** (`lab/`) is an autonomous
improve-mentat loop built on top of the instrument: it calibrates a baseline,
applies a treatment to mentat, runs an experiment arm behind a freeze check and a
build gate, compares it to the baseline under a pre-registered estimand, and
records a verdict in an append-only ledger.

The design follows Karpathy's `_autoresearch` organism — an agent that edits
code, runs a fixed measurement, keeps or discards the change, and logs the
result forever, with a human programming the loop through a `PROGRAM.md`. Here
the system under test is mentat itself, the measurement is `eval/`, and the
target is mentat's productivity and efficiency as a coding agent. The two tools
stay separate on purpose: the instrument never depends on the lab, the lab
consumes the instrument only through its CLI, and during a campaign the
instrument is frozen.

## The measurement pipeline

One eval run drives `mentat run start --json --cwd <workspace>` against a
materialized workspace and writes a per-run artifact directory `<task>-<n>/`
(under `_evals/results/<timestamp>/`, or the `--output` directory). The
permission, sandbox, and max-steps flags the older adapter passed on the command
line do not exist on the current `run start` command, so the subject runs with
default confinement and no step cap; non-interactive confinement and a step
ceiling restore when those knobs return as flags or seeded config. Each run
directory holds:

- `workspace/` — the workspace as the agent left it, minus `_build`.
- `agent.jsonl` — the `--json` event stream, byte-identical.
- `agent.timing.jsonl` — one `{"line":N,"ts_ms":T}` object per stream line,
  stamping each line's arrival time; lines delivered in one read chunk share a
  stamp.
- `session.json` — the persisted subject session document.
- `store/` — the subject's whole per-run data home (sessions, the mutation
  ledger, blobs), archived after the run.
- `git-diff.stdout`, per-command check output, judge prompts and replies.

A schema-versioned `rows.jsonl` at the result root carries one graded result row
per task × run index: series identity (task, agent and version, model, judge
model, mentat version), status, metrics, and one finding per check.

**The session document is ground truth, not the `--json` stream.** The stream is
a progress feed: it carries no tool arguments and no per-response usage. The
persisted `session.json` carries the full ordered event log —
`Provider_settled` (whose `Responded` arm carries the accepted
`Mentat_llm.Response.t` and its per-response usage), `Tool_claimed` (tool name
and canonical input), `Tool_settled` (the model-visible result), and
`Turn_started` (whose declarations are the provider-facing tool snapshot for
that turn). Analysis decodes `session.json` with `Mentat_session.jsont`; it
never reverse-engineers the JSONL stream. The session document has no timestamps
— that is a deliberate invariant of the event model — so wall-clock timing is
recovered separately, from `agent.jsonl` joined with `agent.timing.jsonl`.

`analyze RESULT_DIR` decodes each run's `session.json`, builds a `Trace.t`, and
writes three products:

- `analysis/trace-metrics.jsonl` — one flat object per run: task id, run index,
  then every `Trace_metrics` field (token lanes, tool calls and failures,
  per-segment input growth, cache-hit rate, calls and result bytes by tool name,
  re-read and repeated-call counts, the longest failure streak, the shell
  command-family histogram, and the recovered model and reasoning effort).
- `analysis/digests/<task>-<n>.txt` — one readable transcript digest per run:
  every step's usage lanes and every tool call with elided arguments and
  result head. The digests are the reviewable form of the session and the
  primary source of new hypotheses; the counters quantify only known behaviors,
  so the research program requires reading digests before picking a treatment.
- `analysis.md` — a per-run table joined with each row's success, and a
  per-task **behavior counters** table (rereads, repeated calls, longest failure
  streak, and top shell families, summed over the task's runs) for spotting
  cross-arm behavior deltas and checking a behavior's baseline prevalence.

`analyze` is idempotent and deterministic: rerunning it rewrites the outputs.
Runs with no `session.json` (the `cmd`, `noop`, `claude`, and `codex` adapters
produce none) are skipped and noted once. When `analysis/` is present, `report`
appends a compact per-task trace section.

## Subject blindness and isolation

The threat model is layered. Tier 1 (passive observation — prompt, cwd, file
names and contents, `AGENTS.md`, `git log`/`git status`, build output) is
treated as airtight. Tier 2 (active snooping — `env`, `ps`, walking `..`,
reading `~`) is scrubbed where cheap and its residuals documented. Tier 3
(adversarial forensics) is out of scope. A blindness violation is a harness bug,
and it applies to ordinary eval runs, not only lab campaigns.

**Constructed subject environment.** The `mentat` adapter constructs the
subject's environment rather than passing the developer's through
(`eval/bin/main.ml`, `mentat_run`). It drops **every `MENTAT_*` variable**, then
prepends the toolchain `PATH`, provides a fresh per-run `MENTAT_DATA_HOME`, and a
seeded `MENTAT_CONFIG_HOME` holding a copy of the real `auth.json` when one
exists and a canonical `config.json`; provider API-key variables and the rest of
the environment pass through. Dropping `MENTAT_*` closes two channels at once:
the developer's global `AGENTS.md` and personal model/reasoning/editor overrides
can no longer leak into the subject's prompt, and a config-default treatment can
no longer be silently masked by a user override.

**Neutral workspace and git identity.** Each run materializes its workspace
under the system temp directory with a name derived from the project — never
under `_evals/`, so the agent's absolute cwd carries no marker. The harness
commits a neutral baseline: `git init`, a `.git/info/exclude` for `_build/` and
`.mentat/`, a fixed plausible identity (`Alex Reed <alex@reedholm.dev>`), and an
`Initial commit` message.

**Marker lint.** Between setup and agent start — after the baseline commit,
before the agent runs — `blindness_lint` scans everything the harness introduced
into the agent-visible surface: the workspace path, file names, file contents
(regular files up to 1 MiB), and the injected environment (the inherited `PATH`
tail is exempt, since any local mentat run would see it). It uses
`Mentat_eval.Markers`: the denylist is `eval` (which subsumes `mentat-eval`,
`mentat_eval`, and `_evals`), `benchmark`, `grader`, and `rubric`, matched
**case-insensitively, as substrings, with no word-boundary rule** — `eval` must
match `eval_calc` and `Mentat_eval_smoke`. Word-bounded matching is deliberately
rejected: `_` is a word character in mainstream regexp engines, so it would pass
exactly the leaks the lint exists to catch. A hit fails the run at the `Harness`
stage; a compromised trial is never scored.

**The rule:** nothing the harness introduces may carry an evaluation marker.
Fixtures, prompts, setup commands, and injected environment stay neutral;
treatments change how mentat works, never what it is told about being measured.
Subject sessions no longer land in the developer's store — each subject run gets
a fresh `MENTAT_DATA_HOME` that is captured whole into the run's `store/`.

## The trace library

`mentat_eval_trace` (`eval/trace/`) is a pure, separate library — it depends on
`mentat_session`, `mentat_llm`, and `mentat_tool`, not on `mentat_eval` — so the
core eval library stays agent-agnostic and the dependency arrow runs one way.
Its narrow waist is `Trace.t`, the ordered, usage-attributed view of one session
that capture produces and every analysis consumes:

```ocaml
let trace = Trace.of_session ?timing session in
let metrics = Trace_metrics.of_trace trace in (* flat jsont record *)
```

A `Trace.t` reconstructs, in causal order, the provider responses (`Step.t`,
each with its per-response usage), the executable tool calls each issued and
their model-visible results (`Call.t`, with status ok/failed/rejected and result
byte size), and the compaction resets that delimit **segments** — context-shape
metrics restart per segment because a compaction resets the replay transcript.
Each turn's declared tools (`declared_tools`) are the provider-facing catalog
snapshot for that turn. Shared derivations (`rereads`, `repeated_groups`,
`failure_streaks`, `shell_families`) back the `Trace_metrics` counters, and
`pp_digest` renders a token-bounded view for LLM review.

`Trace_metrics.of_trace` folds a trace into a flat record of counters. Four of
them name behaviors a treatment might target: `reread_count` (unchanged
re-reads), `repeated_call_count` (identical calls beyond the first in their
group), `failure_streak_max` (the longest run of consecutive same-tool
failures), and `shell_families` (the `shell` command-family histogram). Each is
a pure, deterministic fold over the shared `Trace.t` derivations.

**These counters are diagnostic, never decision metrics.** A counter keys on
syntactic identity, so a prompt treatment can zero it without changing anything
real (Goodhart). They earn their keep in two ways — measuring whether a
treatment moved the behavior it targeted (cross-arm deltas), and confirming a
behavior is present at baseline before it is worth treating — and they feed
hypotheses and reports, but decisions run on real resources: tokens, cost,
duration, plus success. This rule is repeated in `Trace_metrics` and the
analysis output because it is the single easiest mistake to make with this data.

## The lab workflow

A campaign runs on a `research/<tag>` branch and stores its state under
`_lab/<tag>/` (gitignored). The lab subcommands are thin and deterministic;
judgement lives in the researcher (the `PROGRAM.md` prompt), policy in
`PROGRAM.md` and `HYPOTHESES.md`.

The lifecycle:

1. **Calibrate** — `calibrate --campaign <tag> --suite <s> --runs N` builds the
   binary, pins the campaign (`campaign.json`: start ref, baseline binary
   digest, and an instrument content digest), runs the baseline arm, and writes
   `calibration/noise.json` — per-task success counts and, over completed runs,
   token and duration median/min/max, plus the per-run mean wall-clock for night
   budgeting.
2. **A/A canary** — `experiment run --aa` runs baseline-vs-baseline through the
   full pipeline to measure the false-candidate rate the decision rules actually
   produce. It must not come out `candidate`; if it does, the thresholds are too
   loose for the measured noise.
3. **Screen** — a treatment on a small suite with a low replicate count, judged
   on efficiency metrics with success as a tripwire.
4. **Confirm** — candidates only, on the larger suite with more replicates.
5. **Ledger** — every experiment, including discards and crashes, appends a row.

**Freeze check and build gate.** Before every measurement `experiment run`
performs two checks, and they exist to defeat the two ways an overnight loop
silently lies:

- The **freeze check** recomputes the instrument content digest — a walk over
  `eval/` and `lab/` (excluding `_build` and `.git`), hashing every file's
  contents — and refuses to start if it differs from the digest pinned at
  calibration. This is stronger than the `git diff <start-ref>` the design
  sketches: it catches untracked files and does not false-positive when a
  campaign legitimately starts from an uncommitted work-in-progress instrument.
  A drifting instrument is not a measurement.
- The **build gate** runs `dune build bin/mentat/main.exe eval/bin/main.exe` itself and
  hard-fails the experiment (ledger status `crash`) on non-zero exit — an
  overnight loop must never "measure" a stale binary because a treatment broke
  the build. It then records the binary digest and **refuses to proceed if it
  equals the baseline arm's digest**, unless `--aa` or `--allow-identical-binary`
  is passed: all treatment tiers compile into the binary (prompts included, via
  `prompts/gen`), so an identical digest means the treatment did not change the
  subject.

**The estimand is pre-registered.** The primary efficiency metric is the
**per-task median of total tokens (`input_total + output_total`) over all
completed runs**, with failed and timed-out runs imputed at the worst value
observed for that task across both arms (pessimistic imputation). Duration is
computed the same way. **Success-only means are forbidden in decisions** — the
success-only figures `Report` computes are diagnostics only. A treatment that
fails the expensive tasks would otherwise "improve" the token numbers by
survivorship: the hard runs drop out of the average and the easy ones look
cheaper.

`experiment compare` pairs per task on the task-set **intersection** (and loudly
lists dropped tasks), computes the estimand, and emits a verdict written to
`compare.md`/`compare.json`:

- **tripwire → discard** — any task all-pass in the reference and all-fail in
  the candidate.
- **guardrail → discard** — success drops on two or more tasks, regardless of
  the primary metric.
- **candidate** — the median of per-task token deltas meets the keep threshold
  (`--threshold`, default 10%); the per-task sign test (improved in K of N
  tasks) is reported alongside.
- **partial** — a verdict computed over a proper subset of the paired suite is
  downgraded and can never be a keep; pre-registration is hollow otherwise.
- When neither arm records token usage (the `cmd`/`noop` adapters), the primary
  metric is unavailable and the verdict falls back to a success-only comparison
  that says so.

`compare` exits `0` on candidate, `1` on discard, `2` on partial or error, and
warns when its reference rows are older than 24 hours — provider drift otherwise
manufactures candidates wholesale. A `candidate` is not a `keep`: the researcher
promotes it to `keep` in the ledger only after it persists in confirmation.

**The dune-exec deadlock.** The lab binary runs a nested `dune build` before
every measurement. Do **not** launch it with a plain `dune exec` while no build
server is running: `dune exec` takes an exclusive lock on `_build`, and the
inner build then deadlocks. Either build once and call the binary directly
(`dune build lab/bin/main.exe && _build/default/lab/bin/main.exe <args>`), or
keep a `dune build --watch` running so both invocations become build-server
clients. The eval binary shells out to `dune` too (for the toolchain `PATH` and
to reach the subject's `mentat` binary), so run it the same way.

## Running it

**Everyday regression check** (a blessed baseline lives at
`eval/baselines/<name>.jsonl`, committed deliberately):

```sh
dune build eval/bin/main.exe bin/mentat/main.exe
EVAL=_build/default/eval/bin/main.exe

$EVAL run --suite core --model openai/gpt-5.5 --runs 3 --output _evals/results/run1
$EVAL analyze  _evals/results/run1
$EVAL report   _evals/results/run1
$EVAL compare  eval/baselines/main.jsonl _evals/results/run1
```

`compare` exits non-zero when the aggregate or any per-task mean score regresses
past tolerance. Suites are `smoke` (a single micro task), `core` (the standard
micro corpus), `long`, `robustness` (both intentionally empty until tasks pass
the rubric), and `all`.

**Research campaign** (the model is chosen per campaign; first campaigns run a
local `gptoss` through the ollama provider, where token cost is ~0 and
wall-clock on local inference is the binding constraint):

```sh
dune build lab/bin/main.exe eval/bin/main.exe bin/mentat/main.exe
LAB=_build/default/lab/bin/main.exe

$LAB calibrate --campaign jul10 --suite core --runs 5 --model ollama/gptoss
$LAB experiment run     --campaign jul10 --name aa --suite core --runs 5 --aa
$LAB experiment compare --campaign jul10 aa            # must not be a candidate

# per hypothesis: apply the treatment, commit, then
$LAB experiment run     --campaign jul10 --name h1 --suite core --runs 3
$LAB experiment compare --campaign jul10 h1 [--threshold 10]
$LAB experiment run     --campaign jul10 --name h1-confirm --suite all --runs 5
$LAB experiment compare --campaign jul10 h1-confirm
$LAB ledger add --campaign jul10 --name h1-confirm --verdict keep \
  --hypothesis "…" --tier T1 --primary-metric tokens
$LAB ledger list --campaign jul10
```

**Token-free harness testing.** The `cmd:` adapter runs an arbitrary command in
the workspace with the task prompt in `MENTAT_EVAL_PROMPT`, exercising
materialization, blindness, grading, and — via the lab binary — the whole loop
with zero tokens. It (and `noop`) produce no `session.json`, so `analyze` skips
them and `compare` falls back to the success-only path:

```sh
$EVAL run --suite smoke \
  --agent 'cmd:printf "let answer = 42\n" > lib/basics.ml'
```

## Extending

**Add a task.** Read `eval/TASK_RUBRIC.md` for admission criteria, add the
fixture under `eval/fixtures/` (a `data_only_dirs` project, so dune does not
build it in place), and register it in the suite selection (`eval/bin/corpus.ml`).
Keep the fixture neutral: plausible product names, an `AGENTS.md` that reads as
an ordinary contributor note, no evaluation vocabulary anywhere the agent can
see it. The marker lint is the backstop, not the licence to be careless.

**Add a counter.** A `Trace_metrics` counter is a pure fold over the shared
`Trace.t` derivations (`rereads`, `repeated_groups`, `failure_streaks`,
`shell_families`) — reuse them rather than re-deriving orderings. Add the field
to the record and its `jsont` codec, gate any opportunity counter on
`declared_tools` so a run whose catalog lacked a tool is never faulted for not
using it, and cover it in `eval/test/test_trace.ml`. It stays diagnostic: a new
counter never becomes a decision metric.

**Design-gated treatments.** Prompt-prose (T1) and output-shaping or config
(T2) treatments edit, build, and run. Tool-semantics, new-tool, and
catalog-shape changes (T3) require a `design-note.md` in the experiment
directory first — problem, alternatives, `.mli` sketch, the relevant `ocaml-*`
design skill loaded — and `.mli`-first implementation. The session, store, and
protocol core, providers, permissions and sandbox, and the instrument itself
(`eval/`, `lab/`) are off-limits to the loop: human-led, outside the campaign.

## What is designed but not yet built

The instrument and loop run today on the existing micro corpus. Several pieces
from the design are deliberately sequenced later, and a reader should not expect
them yet:

- **Reference-anchored corpus families** (comprehension, commit-replay,
  doc-restore, library-build), `Task.jsont` and corpus manifests, the `fetch`
  git mirror cache, and the `mine` pipeline. The current corpus is the micro
  fixtures; `Task` has no JSON codec.
- **Curated `screen`/`confirm` suites with rotating holdouts.** Campaigns use
  `core` as the screening suite and `all` as the confirmation suite in the
  meantime, recorded in every ledger row.
- **`--jobs` parallelism and infra-failure retry.** The runner is sequential;
  budget nights accordingly.
- **Trace review** — the diagnostic LLM judge over `Trace.pp_digest`. The
  digest rendering exists on `Trace.t`, but `analyze` has no `--review-model`
  wiring yet; its findings would feed hypotheses, never row scores.
