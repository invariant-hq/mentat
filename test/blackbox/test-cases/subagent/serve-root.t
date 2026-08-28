A root session served by hand: `mentat serve-session` booted on a session
with no delegation lineage. The boot takes no mode flags — it derives its
shape from the session document, and a document without a delegation
backlink is a root, served plainly. Nothing is minted at boot; the attach
itself is the wake — queue admission runs at attach, so mail already
durable in the journal starts the first turn. The server serves the
session's derived socket while the turn runs, settles, lingers idle, and
exits 0 on its own with the endpoint removed.

The session works in a workspace subdirectory so the fixture and capture
files this test writes are not workspace file changes the turn would drain
as notices. The linger is shortened so the server exits do not pace the
test.

  $ mkdir -p work/.git
  $ (cd work && mentat trust . >/dev/null)
  $ export MENTAT_CHILD_LINGER=1

An empty root session — no turns, no lineage — and one entry mailed before
any server exists: the send takes the fence-held append and the session
stays dormant, the entry waiting for whatever next runs it.

  $ mentat session create --id root-mail --cwd "$PWD/work"
  root-mail
  $ mentat session send root-mail "root errand by mail" --cwd "$PWD/work"
  delivered root-mail
  $ DOC="$XDG_DATA_HOME/mentat/sessions/root-mail/session.json"
  $ grep -o 'queue_updated' "$DOC" | wc -l | tr -d ' '
  1
  $ grep -q 'turn_started' "$DOC" || echo no-turns-yet
  no-turns-yet

The boot: no prompt on argv, no delegation edge — the queued mail is the
work. Attach-at-boot consumes it as the session's first turn, the turn
settles against the scripted provider, and the server exits 0 once the
session lingers idle.

  $ cat > mail.jsonl <<'JSONL'
  > {"expect":{"body_contains":["root errand by mail"]},"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ROOT_MAIL_DONE"}]}]}}
  > JSONL
  $ start_fake_openai mail.jsonl capture port
  $ mentat serve-session --session root-mail --cwd "$PWD/work" >serve1.out 2>serve1.err
  $ wait_fake_server
  $ cat serve1.err

The journal holds exactly the mailed turn: one settled turn whose request
carried the mail body. The queue-entry id is a fresh mint per send, so the
transcript normalizes it beyond what censor's digest markers cover.

  $ grep -o 'turn_finished' "$DOC" | wc -l | tr -d ' '
  1
  $ grep -l 'root errand by mail' capture/request-*.json | wc -l | tr -d ' '
  1
  $ normalize_entry () { sed -E 's/q-\$DIGEST[0-9]+-[0-9a-f]+/q-ENTRY/g'; }
  $ mentat session export root-mail --format text --cwd "$PWD/work" | censor | normalize_entry >root1.transcript
  $ cat root1.transcript
  session root-mail
  phase: idle
  lifecycle: active
  cwd: $TESTCASE_ROOT/work
  events: 5
  1. queue-updated(enqueued({ id = q-ENTRY; input = [1 block(s)] }))
  2. turn-started({ id = $DIGEST2; origin = queued(q-ENTRY); input = user[1 content block(s)]; model = openai/responses:gpt-5.6-sol })
  3. provider-requested({ id = $DIGEST3; turn = $DIGEST2; request = $DIGEST4 })
  4. provider-settled(responded($DIGEST3, "ROOT_MAIL_DONE"))
  5. turn-finished(turn=$DIGEST2, outcome=completed)

The endpoint was announced, derived from the session id under the denied
socket tree, and removed on the clean exit.

  $ SOCK=$(sed -n 's/^mentat serve-session: serving .* at //p' serve1.out)
  $ echo "$SOCK" | grep -c '/s/'
  1
  $ test ! -e "$SOCK" && echo socket-removed
  socket-removed
  $ test ! -d "$(dirname "$SOCK")" && echo socket-dir-removed
  socket-dir-removed

Idle correctness: a re-serve of the settled root attaches, finds a settled
head and an empty queue, and exits 0 on the linger exactly like a settled
delegated child — no new fact, no provider request (the base URL still
names the now-dead fixture server, so any wrongly issued request would
fault the journal and break the diff).

  $ mentat serve-session --session root-mail --cwd "$PWD/work" >serve2.out 2>serve2.err
  $ cat serve2.err
  $ mentat session export root-mail --format text --cwd "$PWD/work" | censor | normalize_entry >root2.transcript
  $ diff root1.transcript root2.transcript && echo idempotent-no-op
  idempotent-no-op

The interrupt carry belongs to the delegated shape — it is the broker's
re-materialization of a cancelled child, and a root session has no parent
whose interrupt it could carry. On a root it is refused loudly.

  $ mentat serve-session --session root-mail --interrupted --cwd "$PWD/work"
  mentat: session root-mail has no delegation lineage; --interrupted applies only to a delegated child
  [1]

A recorded run policy the configuration layer refuses fails the boot
loudly — the session never serves under defaults the grant never named,
and no socket is announced. The document member is rewritten directly, as
a creating host would have recorded it.

  $ mentat session create --id bad-policy --cwd "$PWD/work"
  bad-policy
  $ BAD="$XDG_DATA_HOME/mentat/sessions/bad-policy/session.json"
  $ V=$(mentat_cram json .version "$BAD")
  $ M=$(mentat_cram json .metadata "$BAD" | sed 's/}$/,"run_policy":{"sandbox":"bogus-spelling"}}/')
  $ printf '{"version":%s,"id":"bad-policy","metadata":%s,"events":[]}' "$V" "$M" > "$BAD"
  $ mentat serve-session --session bad-policy --cwd "$PWD/work"
  mentat: session bad-policy: recorded run policy: sandbox: unknown sandbox mode: bogus-spelling
  [1]
