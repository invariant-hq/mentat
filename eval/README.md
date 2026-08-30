# mentat evaluation suite

This directory is the whole evaluation suite: the corpus of OCaml tasks, the
agent adapters, the grading checks, and the `mentat-eval` runner.
Everything lives under `eval/`; run output goes to the git-ignored `_evals/`
directory at the repository root.

The runner is an internal developer tool. It is not installed into the `mentat`
opam package; build it in the tree and run it as
`_build/default/eval/bin/main.exe` (or `dune exec eval/bin/main.exe -- …`).

## Layout

- `lib/` — the pure `mentat_eval` library: usage, checks, tasks, result rows,
  scoring, reports, and marker scanning for subject blindness. Unit-tested in
  `test/`.
- `trace/` — the pure `mentat_eval_trace` library: it decodes a captured
  session document into `Trace.t` (ordered, usage-attributed), then derives
  `Trace_metrics.t` numbers. It depends on `mentat.session`/`mentat.llm`/
  `mentat.tool`, not on `mentat_eval`, so the core stays agent-agnostic.
- `bin/` — the `mentat-eval` executable: workspace materialization,
  subprocess adapters, the judge, artifact IO, corpus suite selection, and
  the `analyze` trace pass.
- `fixtures/` — task fixture projects, copied into fresh run workspaces.
  Declared `data_only_dirs`: some are deliberately broken (failing tests,
  missing docs), so dune must not build them in place.
- `TASK_RUBRIC.md` — admission criteria for adding benchmark tasks.

## Quick start

```sh
dune build eval/bin
dune exec eval/bin/main.exe -- list --checks
# Live run: real mentat against the configured provider.
dune exec eval/bin/main.exe -- run --suite smoke --model openai/gpt-5.5 --runs 1
dune exec eval/bin/main.exe -- analyze _evals/results/<dir>
dune exec eval/bin/main.exe -- report _evals/results/<dir>
dune exec eval/bin/main.exe -- compare <baseline-rows> _evals/results/<dir>
```

`run` drives the locally built mentat binary (`_build/default/bin/mentat/main.exe`)
through `mentat run start --json`. Auth and model configuration come from your
normal mentat environment.

> Wave note. The current `run start --json` stream is the minimal terminal
> envelope set (`turn.finished` / `session.failed` / `session.waiting`) and
> carries no per-run `metrics` object, so the `mentat` adapter records the run
> outcome without usage or tool counters. The rich usage/tool-event stream
> restores with the run-JSONL wave, at which point the adapter reads metrics
> again. Per-run cost is derived from those metrics and from the built-in
> provider catalog, which is not yet re-exposed as a pure value here (see
> Costs), so cost columns are currently absent.

## Suites

`--suite` selects a benchmark tier:

- `smoke` — tiny deterministic tasks for harness and catastrophic-regression
  checks.
- `screen` — a small, cheap subset of `core` spanning categories; the research
  lab's inner-loop suite.
- `core` — common user workflows such as bugfixes, docs, tests, and refactors.
- `long` — larger multi-step engineering tasks. This suite is intentionally
  empty until tasks pass `TASK_RUBRIC.md`.
- `robustness` — adversarial and UX-sensitive tasks. This suite is
  intentionally empty until tasks pass `TASK_RUBRIC.md`.
- `all` — the union of every tier.

Each task records `tier`, `category`, `size`, and `oracle` metadata for report
slicing. See `TASK_RUBRIC.md` before adding tasks.

## Agents

`--agent` selects the adapter:

- `mentat` (default) — `mentat run start --json`; reports usage, turns, tool
  calls, and tool failures from session metrics when the stream carries them
  (see the wave note above).
- `claude` — `claude -p --output-format json`; reports usage and turns.
- `codex` — `codex exec --json`; usage summed from `turn.completed` events.
- `noop` — does nothing; exercises materialization and grading.
- `cmd:COMMAND` — runs COMMAND in the workspace with the task prompt in
  `MENTAT_EVAL_PROMPT`; deterministic harness validation with zero tokens:

```sh
dune exec eval/bin/main.exe -- run --suite smoke \
  --agent 'cmd:printf "let answer = 42\n" > lib/basics.ml'
```

Fields an adapter cannot recover from its agent are omitted from the row,
never zeroed.

> Wave note. The old `mentat` adapter also pinned `--permission bypass`,
> `--sandbox danger-full-access`, and a `--max-steps` ceiling on the command
> line. None of those flags exist on the current `run start` command, so the
> subject runs with default confinement and no step cap. They restore when the
> knobs return (as flags or seeded config).

## Subject isolation and blindness

The agent must not be able to tell it is being evaluated, and must not inherit
the developer's personal mentat configuration. The `mentat` adapter therefore
constructs the subject environment rather than passing the developer's through:
every `MENTAT_*` variable is dropped, and the subject gets a fresh per-run
`MENTAT_DATA_HOME` and a seeded `MENTAT_CONFIG_HOME` holding only credentials
and an empty `config.json` — the subject runs on pure mentat defaults (no global
`AGENTS.md`, no personal model or editor overrides). Provider API keys pass
through.

Each run materializes its workspace under a marker-free temporary root (never
under `_evals/`), commits a neutral git baseline (`Initial commit`, plausible
author), and — between setup and agent start — runs a marker lint over
everything the harness introduced (workspace paths and contents, the injected
environment). A marker hit fails the run at the `Harness` stage: a compromised
trial is never scored.

## Trace analysis

`analyze RESULT_DIR` reads each `<task>-<n>/session.json` captured by `run`,
decodes it with the session codec, and writes:

- `analysis/trace-metrics.jsonl` — one flat object per run: task id, run index,
  then every `Trace_metrics` field (token lanes, tool calls and failures,
  per-segment input growth, cache-hit rate, `calls_by_name`, result bytes,
  re-read and repeated-call counts, the longest failure streak, the shell
  command-family histogram, and the recovered model and reasoning effort).
- `analysis/digests/<task>-<n>.txt` — one readable transcript digest per run:
  every step's usage lanes and every tool call with elided arguments and result
  head. The digests are the reviewable form of the session and where new
  hypotheses come from.
- `analysis.md` — a per-run table (joined with each row's success) and a
  per-task behavior-counters table (rereads, repeated calls, longest failure
  streak, and top shell families, summed over the task's runs).

```sh
dune exec eval/bin/main.exe -- run --suite smoke --model openai/gpt-5.5 --output _evals/results/run1
dune exec eval/bin/main.exe -- analyze _evals/results/run1
```

`analyze` decodes the persisted session document, which carries the full event
log independently of what the terminal `run --json` stream reports. The
`Trace.of_session` reconstruction was re-derived against the current session
event vocabulary (`Provider_settled` responses, `Tool_claimed`/`Tool_settled`
claims, `Message_appended` tool results); see `trace/trace.mli`.

`analyze` is idempotent and deterministic: rerunning it rewrites the outputs.
Runs without a `session.json` (the `cmd`, `noop`, `claude`, and `codex`
adapters produce none) are skipped and noted once in `analysis.md`. The
behavior counters exist to measure whether a treatment moved the behavior it
targeted and to check a behavior's baseline prevalence before treating it; they
key on syntactic identity, so a prompt change can zero one without changing
anything real — never treat them as a decision metric.

When `analysis/trace-metrics.jsonl` is present and `report` is given a result
directory, the report appends a compact per-task trace section (mean tokens by
lane, mean tool calls, mean failures).

## Judging quality checks

Quality criteria are judged only when a judge model is given:

```sh
dune exec eval/bin/main.exe -- run --task words-rev-bugfix \
  --model openai/gpt-5.5 --judge-model openai/gpt-5.5 --judge-samples 3
```

Each sample is one `mentat run start` call (the judge sees the task prompt, the
diff, and the criterion — never the agent transcript) and must answer with a
JSON `{"score", "rationale"}` object. Samples are recorded on the finding;
the judge model is part of the row identity, and rows with different judge
identities should not be averaged together. Without `--judge-model`, quality
checks record `skipped` and are excluded from the base score.

> Wave note. Judge calls previously ran `--ephemeral` (no persistence) and
> `--max-steps 3`; neither flag exists on the current `run start` command, so a
> judge call persists a session to the configured data home and runs uncapped
> until those flags return.

## Costs

Dollar figures are computed at report time from the built-in provider catalog
(`Mentat_provider.Model.cost`), never stored in rows. Pass `--model
provider/model` on `run` so rows carry a resolvable model id; unknown models
report no cost. `report` prints per-task token and cost means over successful
runs plus headline cost-of-success and wasted (failed-run) cost.

> Note. The built-in provider catalog is assembled only behind an effectful
> provider runtime, so the eval binary — which runs without an event loop —
> consults an empty catalog and every cost lookup returns absent. Cost reporting
> populates once the catalog is available to consult as a pure value.

## Results, artifacts, baselines

Each run writes `_evals/results/<timestamp>/` (override with `--output`):

- `rows.jsonl` — one schema-versioned result row per task × run index:
  series identity (task, agent + version, model, judge model, mentat version),
  run index, status, metrics, and one finding per check.
- `<task>-<n>/` — per-run artifacts:
  - `workspace/` — the workspace as the agent left it, minus `_build`.
  - `agent.jsonl` — the `mentat run start --json` event stream, byte-identical.
  - `agent.timing.jsonl` — harness arrival stamps, one `{"line", "ts_ms"}`
    object per stream line (lines arriving in one read chunk share a stamp);
    `analyze` joins it for per-call durations.
  - `session.json` — the captured subject session document (the transcript
    ground truth `analyze` decodes), also archived whole under `store/`.
  - `store/` — the subject's whole per-run data home (sessions, checkpoints,
    todos, goals, blobs): cheap now, unrecoverable later.
  - `git-diff.stdout`, per-command check output, judge prompts/replies.

A baseline is a blessed `rows.jsonl`. To keep one, copy it under
`eval/baselines/<name>.jsonl` and commit it deliberately; `compare` exits
non-zero when the aggregate or any per-task mean score regresses past
tolerance.

## Caveats

- Comparative claims across providers should lead with cost, not raw token
  counts; tokenizers differ.
- The `claude` and `codex` adapters track those CLIs' current headless
  flags; a flag change shows up as `agent_error` rows, not silent zeros.
- One run executes the agent and the checks with a default 600 s wall-clock
  timeout per process tree; task `~timeout_s` overrides it.
