The review-mode read-only seal, enforced end to end: `run review` seals every
command it spawns — its own git first among them — read-only at the OS level,
whatever mode the run is configured with. This test runs under the suite's
danger-full-access pin on purpose: the seal is the review posture's own law,
not a projection of the configured mode. The one workspace write a review
run's machinery actually attempts is git's opportunistic index refresh — a
stat-stale index gives `git diff` a reason to rewrite .git/index, the seal
refuses the write, and git tolerates the refusal silently, so the review
proceeds on an untouched index. The same invocation outside the seal performs
the write; that positive control is what makes the untouched index evidence of
enforcement rather than of a write never attempted — a silently unconfined
seal flips the assertion and fails this test instead of passing it vacuously.

Honest boundary: enforcement is backend-specific (macOS Seatbelt, Linux
Bubblewrap), so this file is gated to those two systems and is skipped
elsewhere. The assertions are backend- and wording-agnostic — filesystem bytes
and the posture's own evidence marker — so one body serves both hosts; it was
authored and run on macOS, and Linux CI exercises the bubblewrap half (the
hand-probe that first established the seal ran under bwrap, the stat-stale
index case included).

The workspace is a subdirectory `ws`, so the harness scratch (fixture, port
file, captures, the index snapshot) stays outside the sealed workspace and the
review diff sees only the repository.

  $ git init -q ws
  $ git -C ws config user.email seal@test.invalid
  $ git -C ws config user.name Sealer
  $ printf 'hello\n' > ws/hello.txt
  $ printf 'stale content\n' > ws/stale.txt
  $ git -C ws add .
  $ git -C ws commit -qm base
  $ mentat trust ws >/dev/null

The dune cram harness injects an unexpanded OCAML_TOPLEVEL_PATH placeholder
the toolchain-root resolver correctly refuses; drop it — a harness artifact,
not a posture under test. A host GIT_OPTIONAL_LOCKS=0 would suppress the very
index write this test observes, on both sides of the seal; drop it too.

  $ unset OCAML_TOPLEVEL_PATH GIT_OPTIONAL_LOCKS

The read-only posture resolves to a real enforcing backend on this host — the
arming check that, when this test fails, separates "the seal broke" from "no
backend was available to hold anything".

  $ MENTAT_SANDBOX_MODE=read-only mentat sandbox status --cwd "$PWD/ws" | grep -o 'evidence=enforced'
  evidence=enforced

Stale the index without changing content — backdating a tracked file's mtime
is what gives git diff its reason to rewrite .git/index — give the review an
actual change to report on, and snapshot the index bytes the seal must
preserve.

  $ touch -t 202001010000 ws/stale.txt
  $ printf 'new line\n' >> ws/hello.txt
  $ cp ws/.git/index index.before

The scripted turn also drives a model-side command under the seal: search_text
runs ripgrep confined, and the matched line's content in the tool result
proves the sealed command could read the workspace — the seal is read-only,
not read-nothing. "stale content" appears in no tool argument, so only a real
read produces it. The turn then emits the findings document.

  $ cat > seal.jsonl <<'JSONL'
  > {"response":{"id":"r1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"i1","call_id":"sc1","name":"search_text","arguments":"{\"pattern\":\"stale c\",\"paths\":[\"stale.txt\"],\"mode\":\"matches\"}"}]}}
  > {"expect":{"body_contains":["function_call_output","sc1","stale content"]},"response":{"id":"r2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"so-item","call_id":"so-call","name":"structured_output","arguments":"{\"summary\":\"seal holds\",\"findings\":[{\"severity\":\"P2\",\"path\":\"hello.txt\",\"line\":2,\"anchor\":\"new line\",\"title\":\"Appended line lacks purpose\",\"body\":\"The appended line introduces an unused entry.\"}]}"}]}}
  > JSONL
  $ start_fake_openai seal.jsonl
  $ mentat run review --uncommitted --cwd "$PWD/ws" >seal.out 2>/dev/null
  $ wait_fake_server
  $ cat seal.out
  {"summary":"seal holds","findings":[{"severity":"P2","path":"hello.txt","line":2,"anchor":"new line","title":"Appended line lacks purpose","body":"The appended line introduces an unused entry."}]}

The sealed run's git had reason to rewrite the index and could not: the bytes
are untouched. The sealed ripgrep read the workspace.

  $ cmp -s ws/.git/index index.before && echo index-untouched
  index-untouched
  $ grep -o 'stale content' capture/request-2.json | head -1
  stale content

Positive control: the identical git invocation outside the seal performs the
write on the very same still-stale state. The write attempt the sealed run
refused is real — an unconfined review git would have refreshed the index and
failed the assertion above.

  $ git -C ws -c core.quotePath=false diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ HEAD >control.diff
  $ cmp -s ws/.git/index index.before || echo index-refreshed
  index-refreshed
