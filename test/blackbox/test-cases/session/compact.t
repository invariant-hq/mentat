Manual compaction (`session compact`) summarizes an idle session's context into
a durable [User_requested] compaction. The summary is one billable provider
claim the driver installs and settles; the command is idle-only.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ cat > compact.jsonl <<'JSONL'
  > {"expect":{"body_contains":["hello prompt"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > {"expect":{"body_contains":["Summarize this conversation","hello prompt"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"A concise running summary."}]}]}}
  > JSONL
  $ start_fake_openai compact.jsonl capture-c port-c

One turn gives the idle session a transcript worth summarizing.

  $ mentat run "hello prompt" --cwd "$PWD" --id compact-me 2>/dev/null
  first answer
  $ wait_child_exit compact-me

`session compact` bills the summary call and installs the fact, printing the
human line naming the session.

  $ mentat session compact compact-me 2>/dev/null
  compacted compact-me
  $ wait_fake_server

The summarizer request actually reached the fake carrying the compaction prompt
over the prior transcript.

  $ grep -o 'Summarize this conversation' capture-c/request-2.json
  Summarize this conversation

The installed fact is durable, and carries the user_requested reason.

  $ mentat session export compact-me --format json 2>/dev/null | grep -o '"reason":"user_requested"' | head -1
  "reason":"user_requested"

The durable summary re-enters framed by the resume notice: the fact carries the
verbatim summary plus the resume wrapper, so a continuing turn resumes the work
rather than acknowledging the summary.

  $ mentat session export compact-me --format json 2>/dev/null | grep -o 'A concise running summary.' | head -1
  A concise running summary.
  $ mentat session export compact-me --format json 2>/dev/null | grep -o 'compacted to save context' | head -1
  compacted to save context

`--json` reports the outcome as a structured envelope.

  $ mentat session compact compact-me --json > skip.json 2>/dev/null
  $ mentat_cram json .type skip.json
  session.compact
  $ mentat_cram json .result skip.json
  skipped
  $ mentat_cram json .session skip.json
  compact-me

A second compaction with nothing new to summarize is a skip: the model view
is already a summary, so no new provider call is billed.

  $ mentat session compact compact-me 2>/dev/null
  skipped compact-me

Manual compaction is idle-only. A never-run session has an empty model view, so
there is nothing to summarize — also a skip, with no provider call.

  $ mentat session create --id empty >/dev/null
  $ mentat session compact empty 2>/dev/null
  skipped empty

An archived or deleted session is refused up front, before any client or model
work, naming its lifecycle.

  $ mentat session archive empty >/dev/null
  $ mentat session compact empty 2>&1
  mentat: session empty is archived
  [1]
  $ mentat session create --id gone >/dev/null
  $ mentat session delete gone --yes >/dev/null
  $ mentat session compact gone 2>&1
  mentat: session gone is deleted
  [1]

A malformed `--model` summarizer override is rejected as invalid input before
any work, exit 2.

  $ mentat session compact compact-me --model 'not a selector' 2>&1
  mentat: model selector must be in the form provider/model
  [2]
