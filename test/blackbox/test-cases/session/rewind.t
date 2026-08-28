Rewind forks a saved session at a turn boundary into a new session whose
transcript is the parent's prefix; the parent is left untouched. This drives the
transform end to end over a real two-turn session (the client-path wiring and the
anchor-resolution refusal live in session.t).

  $ use_trusted_workspace
  $ SOCK_BASE="$(child_sock_base)"

Build a two-turn session against the fake server: turn one, then a resumed turn
two.

  $ cat > t1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["first prompt"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first answer"}]}]}}
  > JSONL
  $ start_fake_openai t1.jsonl capture-1 port-1
  $ mentat run start "first prompt" --cwd "$PWD" --id rw >/dev/null 2>&1
  $ wait_fake_server
  $ wait_child_exit rw
  $ cat > t2.jsonl <<'JSONL'
  > {"expect":{"body_contains":["second prompt"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second answer"}]}]}}
  > JSONL
  $ start_fake_openai t2.jsonl capture-2 port-2
  $ mentat run resume rw "second prompt" --cwd "$PWD" >/dev/null 2>&1
  $ wait_fake_server
  $ wait_child_exit rw
  $ mentat session show rw --cwd "$PWD" | grep '^turns='
  turns=2

Turn ids are clock-derived, so name the boundary by extracting the second
turn_started id from the exported transcript (unique ids sort chronologically).

  $ TURN2=$(mentat session export rw --format json | grep -oE 't-[0-9]+-[0-9a-f]+' | sort -u | tail -1)

Rewinding before the second turn forks a child holding only the first turn; the
child prints its id and keeps just the first prompt.

  $ mentat session rewind rw --to-turn "$TURN2" --id kid --cwd "$PWD"
  kid
  $ mentat session show kid --cwd "$PWD" | grep '^turns='
  turns=1
  $ mentat session export kid --format json | grep -c 'first prompt'
  1
  $ mentat session export kid --format json | grep -c 'second prompt'
  0
  [1]

The parent is untouched: it still carries both turns.

  $ mentat session show rw --cwd "$PWD" | grep '^turns='
  turns=2

The `--after` edge keeps the named turn and drops the rest, so rewinding after
turn one matches rewinding before turn two.

  $ TURN1=$(mentat session export rw --format json | grep -oE 't-[0-9]+-[0-9a-f]+' | sort -u | head -1)
  $ mentat session rewind rw --to-turn "$TURN1" --after --id kid-after --cwd "$PWD"
  kid-after
  $ mentat session show kid-after --cwd "$PWD" | grep '^turns='
  turns=1

Rewinding before the first turn yields an empty-transcript child, equivalent to a
fresh session in the same workspace.

  $ mentat session rewind rw --to-turn "$TURN1" --id kid-empty --cwd "$PWD"
  kid-empty
  $ mentat session show kid-empty --cwd "$PWD" | grep '^turns='
  turns=0

Rewind copies only the mutation ledger prefix its kept turns retain. Drive two
real edit turns — turn one changes f1, turn two changes f2 — then rewind before
turn two: the child's diff and revert see f1's change alone, never f2's.

  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ printf '%s\n' '{"permission":{"rules":{"version":1,"items":[{"action":"allow","matcher":{"type":"any"}}]}},"tools":{"editor":"string-replace"}}' > "$XDG_CONFIG_HOME/mentat/config.json"
  $ printf 'one\n' > f1.txt
  $ printf 'two\n' > f2.txt
  $ cat > m1.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-m1-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-m1-1","call_id":"call-m1-1","name":"edit_file","arguments":"{\"path\":\"f1.txt\",\"old_string\":\"one\",\"new_string\":\"ONE\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-m1-1"]},"response":{"id":"resp-m1-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"did f1"}]}]}}
  > JSONL
  $ start_fake_openai m1.jsonl cap-m1 port-m1
  $ mentat run start --id rw-mut "edit f1" --cwd "$PWD" 2>/dev/null
  did f1
  $ wait_fake_server
  $ wait_child_exit rw-mut
  $ cat > m2.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"edit_file\""]},"response":{"id":"resp-m2-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"item-m2-1","call_id":"call-m2-1","name":"edit_file","arguments":"{\"path\":\"f2.txt\",\"old_string\":\"two\",\"new_string\":\"TWO\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","call-m2-1"]},"response":{"id":"resp-m2-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"did f2"}]}]}}
  > JSONL
  $ start_fake_openai m2.jsonl cap-m2 port-m2
  $ mentat run resume rw-mut "edit f2" --cwd "$PWD" 2>/dev/null
  did f2
  $ wait_fake_server
  $ wait_child_exit rw-mut

The parent recorded both edits, in turn order.

  $ mentat session diff rw-mut 2>&1 | grep -E '^M '
  M f1.txt
  M f2.txt

Rewinding before the second turn keeps only turn one, so the child's copied
ledger carries f1's change alone — f2's later edit is dropped.

  $ TURN2=$(mentat session export rw-mut --format json | grep -oE 't-[0-9]+-[0-9a-f]+' | sort -u | tail -1)
  $ mentat session rewind rw-mut --to-turn "$TURN2" --id rw-kid --cwd "$PWD"
  rw-kid
  $ mentat session diff rw-kid 2>&1
  M f1.txt
  --- f1.txt
  @@ -1,1 +1,1 @@
  -one
  +ONE
  changed 1 file(s) (+1 -1)
  $ mentat session revert rw-kid 2>&1
  would revert 1 file(s):
  M f1.txt
  apply: mentat session revert --apply rw-kid
