`session revert` is the offline-store twin over the revert lifecycle (the
snapshot-backend follow-up): preview by default from the mutation ledger,
`--apply` under a run fence that captures a `Before_revert` safety checkpoint,
freezes the plan before any IO, applies the all-or-nothing edit, and records the
per-path settlement. A stale preflight changes no file.

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"
  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ printf '%s\n' '{"permission":{"rules":{"version":1,"items":[{"action":"allow","matcher":{"type":"any"}}]}},"tools":{"editor":"string-replace"}}' > "$XDG_CONFIG_HOME/mentat/config.json"

Drive one real `edit_file` turn (hello -> goodbye), which records the exact
change rows the revert reads back.

  $ printf 'hello world\n' > note.txt
  $ cat > edit.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-edit-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-edit-1","call_id":"call-edit-1","name":"edit_file","arguments":"{\"path\":\"note.txt\",\"old_string\":\"hello\",\"new_string\":\"goodbye\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-edit-1"]},"response":{"id":"resp-edit-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited"}]}]}}
  > JSONL
  $ start_fake_openai edit.jsonl capture-edit port-edit
  $ mentat run start --id rev-run "change the greeting" --cwd "$PWD" 2>/dev/null
  edited
  $ wait_fake_server
  $ wait_child_exit rev-run
  $ cat note.txt
  goodbye world

The pre-tool boundary the turn captured is an `available` checkpoint over a
`cas.v1` snapshot, not the old `degraded` placeholder (the revert below restores
from it, so the store itself is exercised end to end).

  $ grep -o '"type":"available"' "$XDG_DATA_HOME"/mentat/sessions/rev-run/ledger.jsonl | head -1
  "type":"available"
  $ grep -o '"backend":"cas.v1"' "$XDG_DATA_HOME"/mentat/sessions/rev-run/ledger.jsonl | head -1
  "backend":"cas.v1"
  $ grep -q '"type":"degraded"' "$XDG_DATA_HOME"/mentat/sessions/rev-run/ledger.jsonl && echo degraded-present || echo no-degraded
  no-degraded

`session diff` collapses the recorded change rows to one net entry per path.

  $ mentat session diff rev-run 2>&1
  M note.txt
  --- note.txt
  @@ -1,1 +1,1 @@
  -hello world
  +goodbye world
  changed 1 file(s) (+1 -1)

`--latest` scopes to the most recent editing turn; with one turn it names the
same net change.

  $ mentat session diff rev-run --latest >latest.diff 2>&1
  $ head -n 1 latest.diff
  M note.txt

A fork copies the parent's mutation ledger and blobs, so the child's diff and
revert see the same edit its inherited turn authored — an empty ledger here would
be a dishonest "changed 0 file(s)" over a turn that demonstrably edited. The
hunk body proves the before/after blobs crossed too.

  $ mentat session fork rev-run --id rev-fork 2>&1
  rev-fork
  $ mentat session diff rev-fork 2>&1
  M note.txt
  --- note.txt
  @@ -1,1 +1,1 @@
  -hello world
  +goodbye world
  changed 1 file(s) (+1 -1)
  $ mentat session revert rev-fork 2>&1
  would revert 1 file(s):
  M note.txt
  apply: mentat session revert --apply rev-fork

Rewind copies only the prefix its kept turns retain: rewinding before the single
editing turn yields a child that retains no turn, so its copied ledger is empty
and diff reports nothing — the subset the kept turns define, not the whole
ledger.

  $ TURN=$(mentat session export rev-run --format json | grep -oE 't-[0-9]+-[0-9a-f]+' | sort -u | head -1)
  $ mentat session rewind rev-run --to-turn "$TURN" --id rev-rw --cwd "$PWD"
  rev-rw
  $ mentat session diff rev-rw 2>&1
  changed 0 file(s) (+0 -0)

`session export --format text` renders a numbered transcript over the session's
own event vocabulary (json stays the machine bundle).

  $ mentat session export rev-run --format text > text-export.out
  $ grep -qE '^events: [1-9]' text-export.out && echo has-events
  has-events
  $ grep -qE '^[0-9]+\. ' text-export.out && echo numbered-transcript
  numbered-transcript
  $ mentat session export rev-run --format markdown > md-export.out
  $ grep -q '## Transcript' md-export.out && echo markdown-transcript
  markdown-transcript

`session revert` previews by default — no file is touched — and prints the
copy-pasteable `--apply` invocation.

  $ mentat session revert rev-run 2>&1
  would revert 1 file(s):
  M note.txt
  apply: mentat session revert --apply rev-run
  $ cat note.txt
  goodbye world

The preview `--json` carries the netted changes, the ledger revert-safety read,
and `applied:false`.

  $ mentat session revert rev-run --json 2>/dev/null | mentat_cram json '.ready'
  true
  $ mentat session revert rev-run --json 2>/dev/null | mentat_cram json '.applied'
  false

`--apply` restores the file and reports the confirmed count.

  $ mentat session revert rev-run --apply 2>&1
  reverted 1 file(s)
  $ cat note.txt
  hello world

The revert itself is recorded: the ledger now carries a `revert_started` and a
`revert_settled` fact, and a `Before_revert` checkpoint.

  $ grep -o '"type":"revert_settled"' "$XDG_DATA_HOME"/mentat/sessions/rev-run/ledger.jsonl | head -1
  "type":"revert_settled"

A second revert of an already-reverted session finds nothing to restore (the net
change is now empty).

  $ mentat session revert rev-run 2>&1
  nothing to revert

A stale workspace refuses the whole revert and changes no file. Re-run the edit
into a fresh session, then mutate the target out of band before applying.

  $ printf 'hello world\n' > note2.txt
  $ cat > edit2.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-e2-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-e2-1","call_id":"call-e2-1","name":"edit_file","arguments":"{\"path\":\"note2.txt\",\"old_string\":\"hello\",\"new_string\":\"goodbye\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-e2-1"]},"response":{"id":"resp-e2-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited"}]}]}}
  > JSONL
  $ start_fake_openai edit2.jsonl capture-e2 port-e2
  $ mentat run start --id rev-stale "change note2" --cwd "$PWD" 2>/dev/null
  edited
  $ wait_fake_server
  $ wait_child_exit rev-stale
  $ printf 'diverged\n' > note2.txt
  $ mentat session revert rev-stale --apply >stale.out 2>&1; echo "exit: $?"
  exit: 1
  $ grep -q 'does not match recorded' stale.out && echo stale-detected
  stale-detected
  $ grep -q 'revert refused; no files were changed' stale.out && echo refused
  refused
  $ cat note2.txt
  diverged

Rung 2: reverting a superseded change three-way merges — it keeps
the later edit and applies the reversal — rather than refusing. One turn edits two
disjoint lines of merge.txt; reverting only the first (line 2) is superseded by the
second (line 4), which stays.

  $ printf 'alpha\nbeta\ngamma\ndelta\n' > merge.txt
  $ cat > merge-edit.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-m1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-m1","call_id":"call-m1","name":"edit_file","arguments":"{\"path\":\"merge.txt\",\"old_string\":\"beta\",\"new_string\":\"BETA\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-m1"]},"response":{"id":"resp-m2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-m2","call_id":"call-m2","name":"edit_file","arguments":"{\"path\":\"merge.txt\",\"old_string\":\"delta\",\"new_string\":\"DELTA\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-m2"]},"response":{"id":"resp-m3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"edited"}]}]}}
  > JSONL
  $ start_fake_openai merge-edit.jsonl capture-merge port-merge
  $ mentat run start --id rev-merge "edit two lines" --cwd "$PWD" 2>/dev/null
  edited
  $ wait_fake_server
  $ wait_child_exit rev-merge
  $ cat merge.txt
  alpha
  BETA
  gamma
  DELTA
  $ FIRST=$(mentat session revert rev-merge --json 2>/dev/null | mentat_cram json '.changes[0].sources[0]')

With `revert.merge` off, the superseded selection previews not-ready and apply
refuses — the pre-Rung-2 behavior, and the polarity witness for the config read.

  $ printf '%s\n' '{"permission":{"rules":{"version":1,"items":[{"action":"allow","matcher":{"type":"any"}}]}},"tools":{"editor":"string-replace"},"revert":{"merge":false}}' > "$XDG_CONFIG_HOME/mentat/config.json"
  $ mentat session revert rev-merge --change "$FIRST" --json 2>/dev/null | mentat_cram json '.ready'
  false
  $ mentat session revert rev-merge --change "$FIRST" --apply >off.out 2>&1; echo "exit: $?"
  exit: 1
  $ grep -q 'revert refused; no files were changed' off.out && echo refused
  refused
  $ cat merge.txt
  alpha
  BETA
  gamma
  DELTA

With the gate on (the default), the same selection previews ready and apply merges:
line 2 reverts to beta while the later line-4 edit (DELTA) is kept.

  $ printf '%s\n' '{"permission":{"rules":{"version":1,"items":[{"action":"allow","matcher":{"type":"any"}}]}},"tools":{"editor":"string-replace"},"revert":{"merge":true}}' > "$XDG_CONFIG_HOME/mentat/config.json"
  $ mentat session revert rev-merge --change "$FIRST" --json 2>/dev/null | mentat_cram json '.ready'
  true
  $ mentat session revert rev-merge --change "$FIRST" --apply 2>&1
  reverted 1 file(s)
  $ cat merge.txt
  alpha
  beta
  gamma
  DELTA

Preview matches apply on a non-contiguous selection. An unrecorded external edit
between two recorded changes makes the path non-contiguous; the merge is
orthogonal to that, so the preview must report not-ready — apply
carries no override and refuses Needs_override.

  $ printf 'one\n' > note3.txt
  $ cat > nc-edit1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-nc1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-nc1","call_id":"call-nc1","name":"edit_file","arguments":"{\"path\":\"note3.txt\",\"old_string\":\"one\",\"new_string\":\"two\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-nc1"]},"response":{"id":"resp-nc1b","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first"}]}]}}
  > JSONL
  $ start_fake_openai nc-edit1.jsonl capture-nc1 port-nc1
  $ mentat run start --id rev-nc "first edit" --cwd "$PWD" >/dev/null 2>&1
  $ wait_fake_server
  $ wait_child_exit rev-nc
  $ cat note3.txt
  two
  $ printf 'two\nEXTERNAL\n' > note3.txt
  $ cat > nc-edit2.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-nc2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-nc2","call_id":"call-nc2","name":"edit_file","arguments":"{\"path\":\"note3.txt\",\"old_string\":\"two\",\"new_string\":\"three\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-nc2"]},"response":{"id":"resp-nc2b","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second"}]}]}}
  > JSONL
  $ start_fake_openai nc-edit2.jsonl capture-nc2 port-nc2
  $ mentat run resume rev-nc "second edit" --cwd "$PWD" >/dev/null 2>&1
  $ wait_fake_server
  $ wait_child_exit rev-nc
  $ cat note3.txt
  three
  EXTERNAL
  $ mentat session revert rev-nc --json 2>/dev/null | mentat_cram json '.ready'
  false
  $ mentat session revert rev-nc --apply >nc.out 2>&1; echo "exit: $?"
  exit: 1
  $ grep -q 'non-contiguous' nc.out && echo needs-override
  needs-override
  $ grep -q 'revert refused; no files were changed' nc.out && echo refused
  refused
