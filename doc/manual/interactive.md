# Interactive TUI

Running `mentat` without a command opens the terminal UI. The TUI is the main
interactive product: it keeps the conversation, tool activity, workspace
status, decisions, and saved sessions in one keyboard-driven surface.

```sh
cd ~/project
mentat
```

Press `?` on an empty composer to see the shortcuts available in the current
surface. That sheet is authoritative for individual keys; this guide explains
the workflows behind them.

## Repository activation preflight

Before opening the normal TUI in an unknown workspace, Mentat names the
canonical repository root and asks whether to activate repository config,
instructions, skills, Dune rules, local tools, evaluator access, and Build-mode
project processes. This preflight runs before session creation,
alternate-screen ownership, home-brief construction, or any project process.

The choices are:

1. continue restricted and remember `untrusted`;
2. trust and activate the repository;
3. exit without saving a decision.

The restricted choice is selected by default. Use `1`–`3` or arrows and Enter;
Escape, Ctrl+C, and EOF exit without writing. A persistence error remains in the
preflight for retry. Activation does not approve operations or weaken the
selected sandbox.

Choosing trust saves the decision and reloads the host once. If project
activation fails, Mentat restores the workspace to `untrusted` and keeps the
preflight open with the activation error. If that rollback also fails, the
screen says that `trusted` may remain and prints the exact `mentat untrust ROOT`
repair command; it never reports an activation failure as a save failure.

A workspace already recorded as trusted or untrusted skips the preflight. Run
`mentat trust DIR` or `mentat untrust DIR` and restart to change the decision.
[Workspace trust](workspace-trust.md) covers what activation changes and what
a restricted workspace can still do.

## Starting and resuming

| Command | Result |
| --- | --- |
| `mentat` | Open the home stage in the current workspace. |
| `mentat -p "PROMPT"` | Open the TUI and submit the first turn immediately. |
| `mentat --draft "TEXT"` | Open with `TEXT` in the composer without submitting it. |
| `mentat resume` | Open the home stage with the newest local session ready to resume. |
| `mentat resume --last` | Resume the newest session directly. |
| `mentat resume SESSION` | Resume one session by id. |
| `mentat review [BASE]` | Open the worktree review screen directly. |

The home stage shows the effective model, workspace health, account state,
sandbox posture, activation state, and recent work. A concise warning replaces
repository-controlled details while restricted. Type a prompt to start a new
session. With an empty composer, `enter` resumes the newest session when one is
available; `/sessions` opens the session browser.

`--mode build|plan|review`, `--sandbox MODE`, and `--cwd DIR` override the
corresponding startup choices. A resumed transcript is rebuilt from durable
session facts; live and replayed turns use the same rendering path.

Repository activation does not make Plan or Review execute project tooling.
Build owns configured Dune/Merlin producers; switching away from Build stops
the live project watcher before installing the read-only runner.

## Composer and transcript

`enter` submits the composer. `shift+enter` inserts a newline. While a turn is
running, another submission is queued rather than interleaved with the active
turn; an empty-composer `up` recalls the newest queued prompt for editing. A
queued correction is sent after either a successful turn or an interruption,
but is discarded visibly if the turn fails.

On an empty composer, `up` and `down` recall prompt history and `ctrl+r`
searches it. When the session has delegated agents, `tab` moves keyboard focus
to the conversation switcher — which stacks directly below the composer on a
narrow terminal and sits in the side pane on a wide one; `tab` reaches it either
way. `up` and `down` then move between the main thread and its agents, `enter`
opens the selected conversation, and `esc` (or `tab` again) returns focus to the
composer.

The composer recognizes three prefixes:

- `/` opens and filters the command palette;
- `@` completes workspace paths and agent threads;
- `!` enters shell mode and runs the submitted command through the same
  permission and sandbox posture as agent shell commands.

`ctrl+o` expands or collapses verbose reasoning detail. `pageup` and
`pagedown` scroll the transcript; it stays pinned to new output only while it
is already at the bottom.

`esc` dismisses the nearest transient surface first. During a running turn,
pressing it twice interrupts the turn. `ctrl+c` is reserved for quitting and
requires a second press, so an accidental chord does not discard the session.

## Modes and commands

Build mode is the normal coding workflow. Plan mode asks the agent to propose a
plan and park for approval before implementation. `/plan` and `/build` switch
the mode used by the next turn; the composer frame shows a non-default mode.

The review screen is different from Review turn mode: `/review [BASE]` opens a
worktree UI, while `--mode review` changes the model workflow for a turn.

The palette is the current command catalog. Its main groups are:

- session lifecycle: `/clear`, `/fork`, `/compact`, `/rename`, `/sessions`;
- model and account: `/model` (selects the model and reasoning effort),
  `/login`, `/logout`;
- inspection: `/settings`, `/config`, `/status`, `/usage`;
- display: `/thinking`, `/verbose`;
- workflow: `/plan`, `/build`, `/review`;
- process: `/quit`.

There is no `/skills` command: the TUI does not yet expose a skill inventory.
Inspect skills from the command line with `mentat skills list`.

Commands that replace or mutate the active session — such as `/clear`,
`/fork`, and `/compact` — are available only when the current turn is idle.
Surface and display commands remain available while a turn runs.

## Settings screen

`/settings` opens the settings screen; `/config`, `/status`, and `/usage` open
it on a specific page. `Tab` cycles the three pages, and the arrow keys never
switch pages — so their meaning never depends on which row is selected.

On the config page, `↑`/`↓` move between settings and `←`/`→` change the focused
setting's value. Only the session controls at the top carry an editable value:
`←`/`→` choose a permission review request for the next turn, and `Enter`
applies it — opening model selection on the model row, or sending the chosen
review otherwise. Choosing a value never contacts the engine until you apply it,
so it cannot flicker or revert. `/` filters the visible settings, and `Esc`
clears an open filter before closing the screen. The status and usage pages are
read-only; `Tab` still switches pages there. The model and permission review
controls apply to the next turn only.

## Decisions during a turn

A tool call, plan, or question can park the turn and temporarily replace the
composer with a decision surface. The decision is a session fact: the turn
continues after the answer, and a saved blocked session can be resumed without
losing the pending request.

Permission dialogs distinguish a one-time answer from an exact conversation
grant. Review behavior is selected explicitly when the run starts, and the
active mode limits writes and commands independently of it: Plan and Review
deny both, whatever permission policy would otherwise allow.

Permission is separate from command confinement.
[Permission policy](permissions.md) covers how a decision is reached,
[Permission rules](permission-rules.md) the durable matcher format, and
[Command sandbox](sandbox.md) what an approved command may reach.

## Reviewing the worktree

Open the review screen inside chat with `/review` or directly with:

```sh
mentat review          # HEAD..worktree
mentat review main     # main..worktree
```

The normal layout keeps the changed-file navigation and selected unified diff
side by side. Below 80 columns it shows one focused pane; `tab` switches panes.
Closing an in-chat review returns to the unchanged chat, while closing a direct
`mentat review` run exits the process.

The core review loop is:

- move through files and hunks with the navigation keys shown in the footer;
- press `space` to mark the current scope reviewed and advance;
- press `a` to toggle the whole-feature verdict between pending and approved;
- use `c`/`e` to add or edit a source-backed CR and `x`/`d` to resolve or
  remove one;
- press `t` to close the screen and ask Mentat to review the changes as an
  agent turn;
- press `?` for the complete review key table.

Marks and verdicts persist in the global data home's workspace state, and they
are tied to content: surviving marks carry across a refresh, changed scopes
become stale or unreviewed, and an approval for older content is shown as
stale rather than silently remaining fresh. The screen watches the worktree
while it is open and reports refreshes without discarding the current
orientation or CR draft.

## Sessions and exit

Sessions are saved as turns progress; there is no separate save command.
`/clear` starts a fresh session without deleting the old one, and `/fork`
continues from the current history in a child session. `/sessions` is the
interactive browser; the complete storage and lifecycle commands are in
[Sessions](sessions.md).

On exit, Mentat restores the normal terminal before printing its farewell. When
a session exists, the farewell includes the exact `mentat resume SESSION`
command.
