# Headless runs

`mentat run` runs sessions without the TUI, for scripts, automation, and CI.
The headless surface is a product contract: exit codes and the JSONL event
stream are meant to be depended on.

```sh
mentat run "Add an .mli for lib/user.ml and fix the resulting errors"
echo "Summarize the diagnostics" | mentat run -
mentat run resume --last "Now update the tests"
```

`mentat run PROMPT` is shorthand for `mentat run start PROMPT`. A subcommand
must be the first argument after `run`; a prompt that collides with a
subcommand name can be passed after `--` (`mentat run -- resume`).

## Run flags

`start` and `resume` share the flags below. `--model`, `--reasoning`,
`--permission-unattended`, `--sandbox`, `--require-sandbox`, `--max-steps`, and
the instruction/skill switches are per-run configuration overrides. The other
flags control this invocation directly.

| Flag | Meaning |
| --- | --- |
| `--json` | Emit the JSONL lifecycle stream instead of human progress. |
| `--model provider/model` | Model selector for this run. |
| `--reasoning EFFORT` | `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. An effort the model does not support fails selection before any request. |
| `--mode MODE` | Workflow mode: `build`, `plan`, or `review`. |
| `--permission MODE` | Review posture: `default` asks on review outcomes; `bypass` proceeds through reviews but still enforces denials. Per-run only. |
| `--permission-unattended POLICY` | `block` parks the session and exits 3 when a review is needed; `deny` records a model-visible denial and continues. |
| `--sandbox MODE` | `read-only`, `workspace-write`, `danger-full-access`, or `external-sandbox`. Restricted modes fail closed when unenforceable. |
| `--require-sandbox` | Refuse to run unless the sandbox is enforceable or external. |
| `--max-steps N` | Maximum model and tool steps for the turn (must be positive). |
| `--output-schema FILE` | Require the final answer to match the supported JSON Schema in `FILE`. |
| `-i FILE` / `--image FILE` | Add an image ahead of the prompt. Repeatable. |
| `--attach` | Run the engine through the per-user daemon over its local socket, starting it if needed. |
| `--no-skills` | Disable skill discovery and the skill tool for this run. |
| `--no-instructions` | Disable global and project instruction files for this run. |
| `--no-project-instructions` / `--project-instructions` | Disable or force-enable project instruction files. The two cannot be combined. |
| `--cwd DIR` / `-C DIR` | Working directory override. |

`start` also accepts:

| Flag | Meaning |
| --- | --- |
| `--id ID` | Use this session id instead of a fresh one. Not with `--ephemeral`. |
| `--title TITLE` | Set the new session's title. |
| `--skill NAME` | Pin a skill's guidance as durable user content ahead of the prompt. Repeatable. |
| `--ephemeral` | Persist nothing: the session lives under a throwaway store removed when the run ends. A blocked ephemeral run cannot be resumed. |

See [Instructions and skills](instructions-and-skills.md) for discovery,
precedence, and the difference between cataloged and pinned skills.

`mentat run resume [SESSION | --last] PROMPT` starts a new turn on a saved
session and accepts the same run-shaping flags. `--cwd` is an assertion: a
session resumed from a directory other than its recorded cwd refuses before it
runs anywhere. To reopen a session interactively, use `mentat resume` instead.

## Structured output

`--output-schema FILE` is accepted by both `start` and `resume` and applies only
to that turn. The file is read before the run starts, is limited to 1 MiB, must
contain a JSON object, and is resolved relative to the shell's actual cwd rather
than `--cwd`.

The supported JSON Schema keywords, at any nesting depth, are `type`
(`object`, `array`, `string`, `number`, `integer`, `boolean`, `null`, or an array
of those names), `properties`, `required`, boolean `additionalProperties`, one
schema in `items`, `enum`, and `const`. Annotation-only `$schema`, `$id`,
`title`, `description`, `$comment`, `default`, `examples`, `readOnly`,
`writeOnly`, and `deprecated` are accepted but do not constrain output. Other
keywords, including `$ref`, combinators, `pattern`, `format`, and numeric or
length bounds, are rejected before any provider request. The effective model
must support tool calling.

Mentat adds a `structured_output` tool carrying the schema while leaving the
normal tools available. A non-conforming call is returned to the model with its
violations so it can retry. After three missing or invalid structured-answer
attempts, the turn fails with exit 1.

Without `--json`, a successful run writes only the validated JSON value as one
line; assistant prose does not replace or accompany it. With `--json`, the
successful `turn.finished` has `outcome:"completed"`, `text:null`, and the
parsed value in `output`. Failure to produce a conforming answer emits terminal
`run.output_schema_failed` with a `message`, no `turn.finished` or `output`, and
exits 1 when the structured-answer failure settles the turn. A step limit or
interruption still uses its normal `turn.finished`; provider failures remain
`session.failed`.

## Reviewing a diff

`mentat run review` runs one review turn over an explicit git diff target and
writes a findings document: a summary and a list of findings, each locating
one issue in the reviewed tree. The document is delivered through a built-in
schema, so it is valid by construction — without `--json` it is the entire
stdout, and with `--json` it rides the `turn.finished` event's `output`
member, exactly as a `--output-schema` run does. To turn a findings document
into GitHub review comments, see [GitHub review](github-review.md).

The target is exactly one of:

| Flag | Reviews |
| --- | --- |
| `--base BRANCH` | The worktree — committed, uncommitted, and untracked changes together — against the merge base of BRANCH and HEAD. When BRANCH has an upstream that is ahead, the upstream is used and a warning on stderr names it. |
| `--uncommitted` | The uncommitted worktree changes, untracked files included, against HEAD. |
| `--commit SHA` | The named commit alone, against its first parent. |

The worktree targets append each untracked file to the diff as a new-file
hunk, so a change that only adds files still reviews.

`review` also accepts `--json`, `--model`, `--reasoning`, `--max-steps`
(default 60), `--attach`, and `--cwd`; the workflow mode, review posture, and
output schema are fixed by the verb. The resolved diff is materialized to
`.mentat-review-<session-id>.patch` at the workspace root for the turn — the
session id keeps the name collision-free with your files — and removed when
the run ends, except when the turn parks on a decision, which keeps it for
the resumed session. A kept patch is never itself treated as review content
by a later review, but nothing removes it automatically: delete it yourself
once the parked review is resolved. An empty target diff is a clean no-op: a "nothing to
review" line on stderr and exit 0, with no run started and no provider
contacted. A named revision that does not resolve is a usage error (exit 2);
other git failures, including a workspace that is not a repository, are
runtime errors (exit 1). The exit codes below apply otherwise — in
particular, a turn parked on a decision still exits 3, and the printed
`mentat run reply` continuation resolves it.

## Image input

`-i/--image FILE` is repeatable on both `start` and `resume`. Images are placed
in flag order before the prompt and stored with the session by content reference.
PNG, JPEG, GIF, and WebP are recognized from their bytes, not their filename.
Relative image paths, like schema paths, are resolved from the shell's actual
cwd rather than `--cwd`.

Mentat reads at most 64 MiB from each source file, then enforces the configured
`image.max_count`, `image.max_bytes`, and `image.max_dimension` limits. An image
over the byte limit is downscaled when a supported platform utility is available
and rejected if it still exceeds the limit. Missing files, unrecognized formats,
and limit violations are usage errors before the turn starts. If the selected
model or provider route cannot carry images, the model receives an omission
notice instead of the image. See [Configuration](configuration.md#image-limits)
for defaults.

Image input is not currently supported with `--attach`.

## Daemon attachment

`--attach` means attach the run to Mentat's per-user daemon; it is unrelated to
image attachment. The CLI starts the daemon if needed and communicates over a
local socket. Configuration, trust resolution, and custom-command expansion are
performed for the invoking workspace, while the engine runs in the daemon.
`--attach` is available on `start` and `resume`; it cannot be combined with
`--ephemeral`, and the current daemon transport does not accept `-i/--image`.
An already-running daemon uses the environment it captured when it started, so
restart it after changing environment-provided credentials or settings that its
provider calls need. Per-run flags remain explicit inputs to the attached turn.
See [Daemon and web](daemon-and-web.md) for lifecycle, socket, and compatibility
details.

## Repository activation

The canonicalized invocation directory (or `--cwd`) is both the workspace and
discovery root; Mentat does not search upward for a `.git` directory. Headless
runs never prompt for or infer workspace trust. An unknown or explicitly
untrusted workspace remains useful, but workspace config,
instructions, skills, project-executing tools, and project-local lookup stay
disabled. Native reads, searches, edits, and structural OCaml tools remain
according to workflow and sandbox policy. Mentat prints one warning naming the
canonical root, then continues with user-owned inputs and the restricted
catalog.

Automation that wants repository-controlled inputs or processes must establish
the durable decision explicitly before the run:

```sh
mentat trust /path/to/project
mentat run --cwd /path/to/project "PROMPT"
```

`--sandbox danger-full-access` does not activate a repository, and there is no
per-run trust shortcut. Activation makes the execution surface available; it
does not widen the sandbox.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Runtime error (including a turn that failed). |
| 2 | Invalid command input. |
| 3 | The session is blocked on user action and can be resumed. |
| 124 | Command-line parsing failed. |
| 125 | Unexpected internal error. |
| 130 | A user SIGINT stopped the turn. |

Exit code 3 is the load-bearing one for automation: it means the run stopped on
purpose — a permission review, a plan proposal, a question — and the session is
parked, resumable, with nothing lost. Exit 130 is distinct: the turn was
interrupted by you, and the interrupt is durably recorded so the session stays
resumable.

## Resolving a blocked session

When a run exits 3, Mentat prints the exact continuation. `mentat run reply`
feeds one decision into the blocked session, targeting the pending decision by
its id (copied from `session.waiting`, so a stale command never answers whatever
happens to be pending):

```sh
mentat run reply ID --decision DECISION_ID --allow                 # allow once
mentat run reply ID --decision DECISION_ID --allow-conversation    # exact, for the conversation
mentat run reply ID --decision DECISION_ID --deny

mentat run reply ID --decision DECISION_ID --approve-plan
mentat run reply ID --decision DECISION_ID --approve-plan --message "implementation feedback"
mentat run reply ID --decision DECISION_ID --reject-plan
mentat run reply ID --decision DECISION_ID --reject-plan --message "split the module first"

mentat run reply ID --decision DECISION_ID --answer "yes, target 5.5"
```

Approving a plan continues through the Build turn the approval admits, streaming
its lifecycle events like any other turn.

`run reply` answers pending decisions only — permission, question, and plan. It
has no tool-result verb: interrupting a running tool is not a reply. A turn is
stopped with SIGINT (or the interrupt path), and the engine records the
interruption durably as the tool's own settled outcome; the next resume recovers
from there. There is deliberately no `--tool-interrupted` reply.

An untitled `run start` uses the same default-on automatic title flow as the TUI
before submitting its first turn. It sends the first prompt to `small_model` in
a separate, three-second-bounded provider request, so it can add egress, cost,
and latency. `--title` skips that request; `MENTAT_AUTO_TITLE=0`, `false`, `no`,
or `off` disables it. See [Sessions](sessions.md#automatic-titles) for the full
scope and fallback behavior.

`mentat run reply SESSION --title "New title"` renames the session. A decision
answer and `--title` are mutually exclusive on one invocation.

## JSONL events

With `--json`, each output line is one JSON event carrying `schema_version`
(currently `1`), `type`, `session_id`, and type-specific fields. A run starts
with `run.started` and `session.started`. Depending on the run, later events
include:

- `run.started` — the sandbox posture (`sandbox.mode`, `sandbox.read`,
  `sandbox.network`) and whether the workspace is `trusted`.
- `session.started` — the session this run operates on.
- `turn.started` — `turn_id`, `mode`, `origin`, and `model`.
- `tool.started` — `claim_id`, `call_id`, `tool`, and `stage`.
- `tool.finished` — `claim_id` and `outcome` (`returned` or `ambiguous`).
- `decision.requested` / `decision.resolved` — a permission decision denied by
  `--permission-unattended deny` without parking, correlated by `decision_id`.
- `compaction.installed` — the installed boundary, with its `reason`.
- `queue.enqueued`, `queue.replaced`, `queue.cleared` — one per queue
  transition.
- `turn.finished` — the terminal `outcome` (`completed`, `step_limit`, or
  `interrupted`). A normal completed turn has final `text`; a successful
  `--output-schema` turn instead has `text:null` and parsed `output`. An
  interrupted turn has `reason` (a string or `null`).
- `session.waiting` — the terminal event when the turn parks on a decision;
  carries `decision_id` and the full `decision`, with no preceding
  `decision.requested` required. Pair it with exit code 3.
- `run.output_schema_failed` — the terminal event when a schema-constrained turn
  ends without a conforming answer, including exhausted retries; carries
  `message`. Pair it with exit code 1.
- `session.failed` — the terminal event for a failed turn; carries the failure
  `message`. Pair it with exit code 1.

Correlate `tool.finished` to `tool.started` by `claim_id`; correlate
`decision.resolved` to `decision.requested` by `decision_id`. A parked
`session.waiting` is self-contained; use its `decision_id` directly with
`mentat run reply`. Image input and `--attach` add no event types of their own:
images are validated before `run.started`, and daemon attachment changes the
transport without changing the lifecycle stream.
