# Sessions

Every Mentat run happens in a session, which associates the conversation and
tool calls with related workspace changes and workflow artifacts. The saved
session document contains metadata and the conversation event log.

## Storage

Sessions are global durable data, not project files. On Unix they default to
`$XDG_DATA_HOME/mentat` (or `~/.local/share/mentat`); `MENTAT_DATA_HOME` overrides
the complete root. Each session's durable content uses one percent-escaped
directory:

```text
sessions/
|-- <percent-escaped-session-id>.lock # document-writer lock
`-- <percent-escaped-session-id>/
    |-- session.json               # metadata and conversation events
    |-- run.lock                   # run-fence lock
    |-- ledger.jsonl               # Mentat-observed workspace mutations
    |-- blobs/<shard>/<blob>       # content referenced by mutation records
    `-- attachments/<shard>/<blob> # image media referenced by the conversation
```

The lock files, ledger, and blob trees appear only when needed. Store directories
use `0700` and store files use `0600`. The two lock files coordinate access;
neither contains session content or appears in exports.

`mentat session export SESSION --format json` writes the full archive as NDJSON,
despite the option name: one JSON object per line. It contains a version header,
the complete session document, each mutation event, every referenced mutation or
attachment blob as base64, and a final count-and-digest manifest. A missing,
damaged, or changing artifact makes export fail instead of producing a complete
manifest. Text and Markdown formats are human-readable session-event views, not
full archives. Mentat currently has no public session-import command.

HTML export is also supported:

```sh
mentat session export SESSION --format html -o session.html
```

It produces one self-contained document with inline styling, script, and bounded
images. `--no-timestamp` makes repeated exports byte-reproducible;
`--max-bytes`, `--max-tool-bytes`, `--max-image-bytes`, and `--quiet` control the
rendering limits. HTML rendering does not replace the JSON archive.
Only JSON export supports `--attach`; text, Markdown, and HTML read the local
store directly.

The project `.mentat/` directory is reserved for inputs that may be shared with
the repository: `config.json`, the gitignored `config.local.json`, and project
skills and commands. Ordinary runs do not create project-local session state.

## Automatic titles

A fresh session with no explicit title is titled automatically from its first
prompt in both the TUI and `mentat run start`. The title request happens before
the first turn. It uses `small_model`, falling back to the main model when that
selector is unset, unknown, or unavailable, and times out after 3 seconds.
Failure or an unusable result leaves the session untitled and does not fail the
turn.

Auto-titling is enabled by default. Set `MENTAT_AUTO_TITLE` to `0`, `false`,
`no`, or `off` (case-insensitive) to disable it. This opt-out is useful in
automation because auto-titling sends the first prompt text to the selected
provider in a separate request, can incur provider cost, and adds latency before
the turn. It applies to untitled new TUI sessions and untitled `run start`
sessions, including ephemeral starts; it does not run for `session create`,
`run resume`, or a start with `--title`.

Set or replace a title explicitly with `mentat session create --title TITLE`,
`mentat run start --title TITLE`, or `mentat session rename SESSION TITLE`.

## Resuming

```sh
mentat resume                      # reopen the newest session in this cwd (TUI)
mentat run resume SESSION "..."    # extend a session headlessly with a new prompt
mentat resume SESSION              # open the TUI on a session by id
```

Commands that take a session id accept a unique id prefix. Where supported,
`--last` targets the newest session in the current working directory.
Headless `mentat run resume` requires the exact canonical cwd recorded by the
session. From another directory, pass that directory with `--cwd`; a different
cwd is rejected before the turn starts. An explicit session id remains globally
addressable for non-running lifecycle commands.

## Goals

A goal is standing intent recorded on a session: keep working toward this,
within these bounds, until you declare it done. The process driving the
session — the steward — reads the recorded goal each time the session
settles with nothing queued and sends the next continuation; the model ends
each continuation turn with a `goal_status` claim, and an absent claim means
continue. Done-ness is never written back: the journal's last claim is the
truth. `mentat run --goal` is the headless steward — see
[Headless runs](headless.md#goals).

## Lifecycle commands

```sh
mentat session list [--all] [--archived] [--deleted] [-n N] [--json]
mentat session show SESSION        # metadata, execution status, and next steps
mentat session search QUERY        # search saved session metadata
mentat session create [--id ID] [--title T]
mentat session rename SESSION TITLE
mentat session fork SESSION [--id CHILD] [--title T]
mentat session rewind SESSION --to-turn TURN [--id CHILD] [--after]
mentat session archive SESSION     # hide from default listings
mentat session restore SESSION
mentat session delete SESSION      # tombstone (asks for confirmation)
mentat session purge --yes          # permanently remove deleted sessions
mentat session export SESSION [--format json|text|markdown|html] [-o FILE]
mentat session compact SESSION     # compact context out-of-band
```

`--all` lists sessions across working directories; by default listings are
scoped to the current one.

`fork` copies the whole parent into a new child and leaves the parent
unchanged. `rewind` is fork-at-a-turn-boundary: `--before` (the default) drops
the named turn and everything after it; `--after` keeps the named turn and
drops only later turns. Rewind reshapes the transcript only; to undo the
workspace changes from dropped turns, use `session revert` with an explicit
turn, change, or path scope on the source session.

## Diff and revert

Mentat records every workspace change it authors, per turn. You can inspect
and undo them without touching your own edits:

```sh
mentat session diff SESSION --latest          # what the last turn changed
mentat session diff SESSION --turn TURN
mentat session diff SESSION --path lib/foo.ml

mentat session revert SESSION --latest        # preview the revert
mentat session revert SESSION --latest --apply
mentat session revert SESSION --change ID --apply
mentat session revert SESSION --path lib/foo.ml --apply
```

`revert` previews by default and prints the exact `--apply` command when the
plan is clean. Before applying, Mentat records a pre-revert checkpoint when a
checkpoint backend is available, so a revert is itself recoverable.
