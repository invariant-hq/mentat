Routine installation fails closed: the library's strict decode refuses unknown
members and unimplemented trigger kinds with the offending member named, and
the store refuses a loose-permission secret the way sshd refuses a loose key.

  $ scaffold() {
  >   mkdir -p "$1"
  >   printf 'Review the diff.\n' > "$1/prompt.md"
  >   printf '{"type":"object"}\n' > "$1/findings.schema.json"
  > }

An unknown member anywhere in the document is a load error naming it, never a
lenient read.

  $ scaffold unknown
  $ cat > unknown/routine.json <<'EOF'
  > { "routine": 1, "name": "u", "bogus_member": true,
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ mentatd routine add unknown 2>&1
  mentat: install: unknown/routine.json: unknown member "bogus_member"
  [1]

A recognized-but-unfunded trigger kind is refused as unimplemented, distinctly
from an unknown kind.

  $ scaffold sched
  $ cat > sched/routine.json <<'EOF'
  > { "routine": 1, "name": "s",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "schedule" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ mentatd routine add sched 2>&1
  mentat: install: sched/routine.json: trigger[0].kind: "schedule" parses but is refused as unimplemented
  [1]

A loose-permission secret file breaks the routine: the re-validating add — and
every later load — refuses it, naming the mode.

  $ scaffold loose
  $ cat > loose/routine.json <<'EOF'
  > { "routine": 1, "name": "loose",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [
  >     { "kind": "github_webhook", "events": ["pull_request.opened"] } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ mentatd routine add loose >/dev/null
  $ chmod 644 config/mentat/routines/loose/secrets/webhook
  $ mentatd routine add loose 2>&1
  mentat: load: $TESTCASE_ROOT/config/mentat/routines/loose/secrets/webhook: mode 644 grants group or world access; make it private (chmod go-rwx)
  [1]
  $ mentatd routine list | censor
  NAME   DIGEST  STATE  AUTH  LAST
  loose  -       -      -     load: $TESTCASE_ROOT/config/mentat/routines/loose/secrets/webhook: mode 644 grants group or world access; make it private (chmod go-rwx)

A proposal must not carry secrets: they are created at install, never copied
out of a repository checkout.

  $ scaffold smuggle
  $ cat > smuggle/routine.json <<'EOF'
  > { "routine": 1, "name": "smuggle",
  >   "workspace": { "repo": "acme/widgets" },
  >   "trigger": [ { "kind": "cli" } ],
  >   "run": { "mode": "review", "prompt": "prompt.md",
  >            "output_schema": "findings.schema.json" },
  >   "budget": { "per_run": { "wall_clock": "15m" } },
  >   "publish": { "github": "review-threads" } }
  > EOF
  $ mkdir smuggle/secrets && printf 'leak\n' > smuggle/secrets/webhook
  $ mentatd routine add smuggle 2>&1
  mentat: install: smuggle/secrets: a routine proposal must not carry secrets; it is created at install
  [1]
