# RFC 0023: The notify-the-agent layer — one watch, settled readings, stated differences

- Status: `discussion`. (Lifecycle: `ideation → discussion → published →
  committed | abandoned`. `committed` means the document describes how the
  system works, not what we intend.)
- Audience: Mentat maintainers; the turn-agent (RFC 0011), workspace-io
  (RFC 0009/0021), and TUI (RFC 0016) authors; the litany maintainer.
- Derives from: RFC 0011 §6 (`drain_notices` is the whole intake; notices are
  durable, turn-scoped facts), RFC 0016 Q14, RFC 0021 (the sealed route),
  RFC 0009 L1 (one spawn boundary).
- Amends: `lib/ocaml/dune_rpc/rpc.mli:44-66` "it never starts Dune" — the
  executable now starts it through `Command.start_session`, so RFC 0009 L1 is
  unchanged. RFC 0016 row 10 resolves as pull (§8); the engine pulse stays
  owed (§15).
- Provenance: a 13-question source audit, corrected after `_ref/dune` was
  advanced to the nightly the maintainer runs (the audited hang mechanisms
  belong to the old build loop); four blind designs; four adversarial lenses
  whose findings and dispositions are in the campaign's fold ledger.

## Summary

Mentat owns one confined eager `dune build --watch` per trusted OCaml
workspace, and tells the model only the *difference between consecutive
settled readings* of that watch's diagnostics — per lane, build and lint.
Four rulings:

1. **Mentat is the spawner, dune is the loop.** The watch is spawned through
   the sealed `start_session` route under the agent's own sandbox policy and
   supervised. Mentat never drives builds: dune's eager loop rebuilds on
   every file change — the agent's, the user's, the editor's — and the user's
   editor sees the same watch. Where a watch already runs, Mentat attaches
   instead of fighting for the lock.
2. **A reading is the diagnostic stream at rest.** The producer folds dune's
   own `Add`/`Remove` diagnostic events into a store and takes a reading only
   when the stream is quiet and the build is not in progress. The
   clear-then-republish window and the 15-second recovery guess disappear
   because nothing is read mid-build.
3. **The change law is set equality over content keys** —
   `(lane, severity, path, first message line)`, never dune's per-build id,
   never the line number. Same set → silence; a different set → one notice
   naming what is new and what resolved; empty after non-empty → recovery.
   Lint findings have their own source: the configured lint command
   (litany by default), run after each green settle over the artifacts that
   build just wrote, its output parsed with dune's own `ocamlc-loc` — the
   lanes separate by construction, not by convention.
4. **Every lock-taking one-shot yields.** `ocaml_dune_describe` is deleted;
   the docs and eval tools refuse honestly while Mentat holds the lock, until
   a lease lands. The separate-build-dir idea (`TODO.md:6`) is killed (§12).

Litany is not pinned into Mentat (§14 Q1): the linter is the project's tool,
version-coupled to the project's compiler, reached through dune's alias
contract.

## Motivation

**The producer guesses.** Build health today is a one-shot 0.5 s registry
probe per drain (`bin/workspace_notices.ml:163-168`) that cannot ask dune
whether it is mid-build. Because dune empties its error set at build start, a
probe landing there reads "clean" on a broken build, so recovery is confirmed
by a 15-second heuristic (`workspace_notices.mli:40-56`) that a slow rebuild
defeats in both directions. "Change" is a head string — the first
diagnostic's first line (`workspace_notices.ml:78-97,154`): a second error
changing while the first stays is silent; one of three errors fixed is
silent; the same error moving a line is not.

**Nobody starts the watch.** Mentat observes an already-running
`dune build --watch` only (`lib/ocaml/dune_rpc/rpc.mli:44-66`;
`bin/composition.ml:1987-2003`). A fresh checkout has none, so the first hour
of agent work is unobserved; and the hang the maintainer observed — a watch
answering `ping` while forwarded builds never complete — cannot be mitigated
by a process that owns nothing.

**The lock conflict is wider than one tool.** `dune describe` cannot run
beside a watch, and neither can the docs tool's `describe workspace`
(`lib/tools/ocaml/docs.ml:1858-1860`) nor eval's `dune ocaml top`
(`lib/tools/ocaml/eval.ml:408`) — all three take dune's build lock (§7).
Retiring describe alone would leave two tools printing dune's "please delete
`_build/.lock`" advice to a model that would obey it.

**Lint has nowhere to enter.** Litany 1.0.0 ships an in-build lane whose
output is dune's own diagnostic grammar, but the producer counts every
diagnostic as "Build failing" and cannot tell a lint finding from a compiler
warning.

## 1. Guide-level: what a user sees

Open a trusted dune workspace and start a turn. The side pane's `workspace`
section shows `dune · starting`, then `dune · building`, then `dune · clean`
or `dune · 3 errors`. Save a file in your editor: `dune · building`, then the
verdict. ocaml-lsp in that editor sees the same watch through dune's
registry.

Ask the agent for a change. Its edit tool writes; dune rebuilds; the next
request the model sends opens with:

```
Workspace notices:
- [error] dune: Build failing (2 errors: 2 new)
lib/inventory.ml:5:17-5:40: This expression has type string but an expression was expected of type int
lib/store.ml:12:3-12:9: Unbound value restock
```

The model fixes one and runs `dune build` in the shell — which forwards to
Mentat's watch, as dune has done since 3.18 — and the request that follows
says `Build failing (1 error: 0 new, 1 resolved)` with `1 unchanged since the
last notice`; the last fix earns `- [info] dune: Build recovered`. Nothing is
said while the set is unchanged, however many rebuilds happen. If litany resolves on the project's PATH (or `dune.lint_command` names
another linter), Mentat runs it after each green settle and the findings
arrive on their own lane:

```
- [warning] lint: 2 findings (2 new)
lib/inventory.ml:5:17-5:40: comparison through List.length is a needless emptiness test [needless-list-length]
lib/inventory.ml:7:43-7:52: physical comparison has a non-immediate operand [suspicious-physical-equality]
```

and `- [info] lint: Lint clean` when they are gone.

If the watch stops answering, the row reads `dune · hung · restarting`, then
`dune · building`; the model's in-flight `dune build` fails with dune's own
error text, and its next request explains why:

```
- [warning] dune: Build watch restarted (stopped responding to builds)
A dune command that was running may have timed out, or failed with
"Connection terminated" or "Build via RPC failed"; run it again.
```

If you already run your own `dune build -w`, Mentat attaches to it: the row
reads `dune · theirs · clean` and notices come from your watch. Stop yours
and Mentat starts its own.

## 2. The watch: ownership, route, lifecycle

**Argv and mode.** `<dune> build --root . --watch <targets>`, `dune`'s
resolvability probed on the sealed child PATH and the launch resolving the
bare name again on the same route — the watch is the same dune the confined
shell's forwarded `dune build` finds (the one-shot tools still run the
toolchain-resolved dune; a skew between the two is doctor's parity problem).
Cwd the workspace root. Targets: `dune.targets`
(default `["@check"]`) — the lint alias is never among them (§5: lint is a
one-shot with its own cadence, not a watch target) — `@check`, not
`@default` or `@all`, because it is what merlin,
ocaml-lsp, and litany's rule consume, without linking: on this repository
`@default` relinks up to 129 executables (1.9 GB) per touched library;
`@check` relinks nothing. The agent's forwarded `dune build` adds `@default`
to that iteration (the nightly merges RPC goals into the running request), so
link failures surface exactly when the agent links. Eager, not
`--passive-watch-mode`: passive builds only on request, so the agent's edit
and the user's save would trigger nothing until Mentat asked, and the
editor's diagnostics would go stale between asks.

**Route and posture.** `Mentat_workspace_io.start_session build_capability
~sw argv` (`mentat_workspace_io.mli:712-738`): the confined, supervised route
background terminals use. The watch runs **confined under the agent's sealed
policy**, on purpose: it executes every `(rule (action …))` the model writes
into a `dune` file, at file-watcher latency, with no tool call in between —
an unconfined watch would be an escalation route around the sandbox that
confines the agent's own `dune build`. The socket `<root>/_build/.rpc/dune`
is inside the writable primary root, reachable by the confined agent child
(seatbelt admits `network-outbound` under every writable subpath,
`lib/sandbox/seatbelt.ml:285-304`; bubblewrap's `--unshare-net` does not
touch pathname `AF_UNIX`).

**The registry, without admitting it.** Dune writes its registry entry with
an unguarded `write_file` at server start (`_ref/dune/src/rpc/
registry.ml:27-45`) into `$XDG_RUNTIME_DIR/dune/rpc`, else
`~/.local/share/dune/rpc` — a global, persistent directory that must never be
agent-writable (an entry there is parsed unvalidated by every dune client and
every Mentat session on the machine), and under bubblewrap's unconditional
`--unshare-pid` (`lib/sandbox/bubblewrap.ml:95`) the entry would be named by
a namespace pid. So: the watch is spawned with
`XDG_RUNTIME_DIR=<root>/.mentat/run/watch-<pid>` — inside the Write root,
read by nobody else, its content never parsed (the supervisor counts entries;
the mirror is fabricated host-side), stale sibling directories of dead hosts
swept at engage — and Mentat **mirrors** the entry into the user's real
registry host-side, unconfined, with `pid = Session.pid` (the host pid) and
the socket path, unlinking the mirror on every exit path. ocaml-lsp discovers
the mirror; the agent can touch neither the real registry nor another
project's. The mirror is an editor courtesy only: its failure costs
discovery, never the agent's readings (see Discovery). Mentat's own
foreign-mode picker rejects entries whose pid is provably gone (`ESRCH`);
`EPERM` is evidence of life, and the initialize handshake — not the entry —
is what admits a server.

**Discovery.** Mentat knows its watch's pid and socket: the supervisor
**pins** that endpoint into the shared observer, whose attach loop bypasses
the registry while the pin holds — it never polls the registry for its own
watch, so a broken or unwritable user registry silences editor discovery,
never the agent's build visibility. Registry discovery survives for foreign
attach only. The pinned attachment also carries its identity: the connection
reports the watch as ours, and the lane fact of §4 — the supervised watch's
targets are known — travels with the pin.

**Lifecycle.** The supervisor is constructed on first demand beside the
shared observer, under the instance switch — construction is pure, and the
projection layers that only read its health never construct or engage
anything. It engages **lazily, at the first turn's preparation** — never at
daemon boot, so opening a TUI on a cold monorepo does not start a build, and
`mentat run`/cram one-shots spawn only when a turn actually drains. Stop
stops the machine first (a pending restart never respawns mid-shutdown),
then `Session.signal` (SIGTERM to the group, a daemon-scale grace so dune's
exit handlers outrun the SIGKILL, issued before the switch releases) — dune's
`at_exit` unlinks its socket and private registry entry where the signal
reaches it; on Linux the sealed route's `bwrap --new-session` detaches the
child from the signalled group, so the supervisor unlinks the socket and
private entries host-side once the child settles — same end state, different
hand. The switch's own release — Eio's child-only SIGKILL
(`mentat_workspace_io.mli:598-603`) — is the backstop, and the mirror is
unlinked host-side either way.

**The machine** (one vocabulary — the machine's word either defers to the
observer or announces a §8 wire value; `Mentat_ocaml_dune_rpc.Watch` is the
pure law, and an observed attachment always wins the composition):

```
Off _ ─first drain─▶ Probing ─socket answers initialize─▶ Live {Theirs pid; …}
Probing ─no server─▶ Starting ─initialize─▶ Live {Ours; Building}
Live {Ours; _} ─exit─▶ re-probe: a server answers ⇒ Live {Theirs _} else Restarting (Exited _)
Live {Ours; _} ─hang (§3)─▶ Restarting Hung
Restarting _ ─1 s─▶ Starting        (two consecutive lives dying before Live ⇒ Off Gave_up)
Live {Theirs _; _} ─connection EOF─▶ Probing   (held through the immediate
                                                re-poll, so a transient EOF
                                                never flaps the row off)
```

Under `dune.watch = observe` nothing is spawned and nothing announced — the
observer speaks alone, and its discovery is registry-only. A foreign watch
that answers the socket but has no usable registry entry is invisible under
observe; under `auto` the machine holds `Probing` beside it, honestly short
of attached. The `_build/.lock` pid fallback is deliberately not built:
foreign discovery is one mechanism, not two. A dune that does not resolve at
all is `Off No_dune` before any probe.

The pre-spawn **probe** exists because a spawned `dune build --watch` under a
held lock does not fail: it forwards one build to the holder and exits 0/1
(`_ref/dune/bin/build.ml:173-204` — the watch flag is consulted only in the
lock-acquired branch), so the lock message never reaches a supervisor.
Probing connects to `<root>/_build/.rpc/dune` and initializes; an answering
server means **foreign attach**: the same readings run against it, the row
says `theirs`, and it is never signalled (L7). A watch that reached `Live`
resets the give-up counter. `/dune restart` forgives every terminal off —
`Gave_up`, `Blocked`, and the user's own `/dune stop` — by clearing the stop
latch and cycling from `Probing`; a new session does the same by
construction.

## 3. Hang detection

The observed hang belongs to the old build loop (the maintainer confirms an
old dune; the nightly rewrote the loop and merges RPC requests into the
running build), so mitigation here is insurance, and detection is
behavioural — a bounded request that must complete — never a claim about a
code path. `ping` is never the signal: it is `fun _ -> Fiber.return`
(`_ref/dune/src/dune_rpc_impl/server.ml:248`).

**No periodic probe — evidence, then one verification.** A standing timer
would spend a request every `B` for the lifetime of every healthy watch to
insure against a bug no shipped configuration is known to still have; the
evidence path spends nothing until something actually stalls. The signal is
the one place a hang is observable: a shell command whose program resolves
to dune, run while the watch holds the lock, times out — that command was
forwarding into the watch, and its timeout is a **stall report** to the
supervisor. The composition cannot see the lock, so every dune command's
timeout reports, and the supervisor verifies only while it supervises a
live watch of its own — a report with no such watch behind it is dropped.
The supervisor then runs one bounded `flush_file_watcher` as
verification: the public procedure that waits for the file watcher's sync
round-trip and the debounce quiet period (`build_loop.mli:28-31`) — it
exercises dune's event loop and never waits on the build, so a merely slow
build completes it while a wedged loop cannot. The flush completing (or any
progress or diagnostic event arriving in its window — file churn
legitimately extends the debounce) clears the report: the build was slow,
not stuck. The flush timing out is the verdict: `Session.signal`,
`Restarting Hung`, respawn. The model's failed command already carries
dune's own RPC error and the next drain carries the `dune.watch` notice
naming the restart, so the journal counts restarts by kind. A false
positive costs one incremental restart, and only a session that both hit a
tool timeout and failed verification can pay it.

The verification bound derives: one flush, bounded to 10 s — 100× dune's
0.1 s debounce, and well inside the retry the failed tool's error message
already told the model to make. Test-only env scaling, never §9 knobs:
`MENTAT_DUNE_WATCH_FLUSH_S` for the bound, and `MENTAT_DUNE_RPC_QUIET_S`,
`MENTAT_DUNE_RPC_QUIET_FALLBACK_S`, `MENTAT_DUNE_RPC_RECONNECT_S` for the
reading windows a hermetic fake cannot wait out.

The **first** flush after `Live {Ours}` is the one unconditional flush, and
doubles as the confinement self-test: if it never completes on a fresh
watch, the state is `Off (Blocked "file watcher blocked by the sandbox")`
at once — no restart budget spent, one warning notice naming the seatbelt
allowance (§13 slice B).

A synthetic *build* probe is deliberately absent: under the nightly a build
request cancels and restarts a running build, and its completion time is the
whole rebuild's — a probe that either disturbs the loop or times out on slow
builds. The agent's own forwarded builds already traverse the exact path
that can hang, bounded by the shell tool's timeout — which is why that
timeout, not a timer, is the stall signal above. A standing periodic flush
was designed and rejected: it prices insurance at a request every 10 s per
healthy watch, forever, against a bug only unshipped configurations are
known to have — the evidence path pays only on evidence.

## 4. Readings and the change law

**The store.** The supervisor holds one persistent connection with two
long-polls, each on its own fiber (the fiber adapter is an identity monad,
`rpc.ml:29-77`, so an outstanding poll owns its fiber): `diagnostic` and
`progress`. The `diagnostic` stream is dune's own `Add`/`Remove` diff of its
error set — and because dune mints fresh ids per build, any build that
touches an error produces events even when the content is identical, making
the stream an exact **build witness**. The store is the fold of those events.
The `progress` stream is a 0.2 s *sample* with equal-state coalescing
(`server.ml:222-243` `Source.Computed {poll_every = 0.2 s}`,
`long_poll.ml:42-47`): a sub-sample rebuild produces no progress event, so
progress alone can neither confirm nor order a settle. There is no one-shot
`diagnostics` request.

**A reading** is the store when it has synchronised at least once since the
connection opened — dune answers a stream's first poll immediately, an empty
set included, so pre-sync emptiness is ignorance, never cleanliness — the
diagnostic stream has been quiet for 0.25 s, and the last progress sample is
a settle (`Waiting` and `Interrupted` block a reading exactly as
`In_progress` does: nothing has settled). **A recovery
candidate** (a lane's store empty after a non-empty baseline) is stated only
when a progress settle event (`Success`/`Failed`) arrived after that lane's
last `Remove` — proof the build that removed them finished — with one
fallback: 2 s of diagnostic quiet at a settle states it anyway, because
coalescing can swallow the settle event of a sub-sample `Failed → Failed`
rebuild. Failing
transitions state on the 0.25 s quiet alone; a false failing is impossible
(the events are dune's own), and the asymmetry follows the cost of being
wrong — a false recovery tells the model to stop working on a broken build.

```ocaml
(* Mentat_ocaml — the pure OCaml-tooling vocabulary, beside Diagnostic *)
type Finding.t = { lane : Build | Lint; severity : Error | Warning;
                   path : string option; range : … option;   (* attribute, not identity *)
                   head : string; detail : string list }
val Finding.key : t -> string
  (* lane ^ severity ^ path ^ head — the range is not identity *)
type Reading.t = { findings : Finding.t list; lint_requested : bool }
val Change.step : stated:Reading.t -> Reading.t -> Change.t list * Reading.t
  (* total, pure, clock-free; per lane *)
```

**Lanes.** A finding's lane is its source, structurally: everything on the
watch's RPC stream is `Build`, everything the lint runner (§5) parses is
`Lint`. There is no text convention and no classifier — a watch that builds
a lint alias (the user's own choice of targets) reports those findings as
build errors, because that is what dune itself reports for it: its watch
prints `Had n errors`, its `dune build` exits non-zero, its CI fails, and
Mentat echoes the watch it observes rather than re-adjudicating it. Under a
foreign watch `lint = None` when the runner is off — lint-absent, not
lint-clean, so nothing states `Lint clean` that no linter earned.
Severity note: a `Warning` diagnostic exists only when an action *failed*
(success prints to the console and produces none), so a warnings-only build
lane is `Failing {errors = 0; warnings = n}`, titled `Build failing
(n warnings)` — dune's own console agrees ("Had n errors").

**The law**, per lane, `stated` initially empty:

| stated | current | result |
|---|---|---|
| any | no reading | nothing; `stated` unchanged |
| S | S (as key sets) | nothing |
| ∅ | S ≠ ∅ | `Failing {fresh = S; resolved = ∅}` |
| S₀ ≠ ∅ | S ≠ ∅, S ≠ S₀ | `Failing {fresh = S \ S₀; resolved = S₀ \ S}` |
| S₀ ≠ ∅ | ∅ | `Recovered` (confirmed as above) |

Lanes are independent: each has its own `stated`; the verdict is the build
lane alone, never `Progress` — a lint-only failure leaves the build verdict
`Clean`. `lint = no reading` when the lane is off: `stated.lint` is then
frozen and silent; disabling the runner deliberately
(`dune.lint_command = []`, or removing the linter) resets `stated.lint` to
∅ silently — the reset is the session boundary, not a mechanism: config
resolves at boot and the stated baseline is session memory, so the next
session starts at ∅ and findings that return with the runner are `new`. A watch `Off` for an hour that settles on
the stated set is silent; a different set is stated as the difference from
the last notice, however old — the model was told nothing in between, so
nothing in between is owed.

**Model-visible text** (`render_notices`, `lib/agent/step/
mentat_agent_step.ml:1133-1150`, unchanged): title `Build failing (n errors
[, m warnings]: k new, r resolved)`; body = every fresh finding as
`path:l:c-l:c: head`, the path workspace-relative (dune reports absolute
paths; columns are ocamlc's 0-based end-exclusive offsets), then
`n unchanged since the last notice`; at most 20
findings then `… and k more` — a notice rides every continuation request of
its turn, and 20 lines is ≈ 0.5 KTok per request. Sources `dune` and `lint`;
keys `dune.build`, `dune.lint`, `dune.watch` (coalescing per
`notice.mli:64-79`).

**The drain.** `drain_notices` (`lib/agent/ports.mli:335-347`) becomes a
mutex-guarded read of the supervisor's store plus `Change.step` — no RPC on
the driver fiber, ever; today's per-drain 0.5 s probe disappears. A build
that settles after the drain that followed the edit is stated at the next
drain, which in the common flow — edit, then `dune build` in the shell — is
the same request that carries the shell result.

## 5. Lint

The runner executes `dune.lint_command` — `["litany"; "check"]` by
default; a default, not a coupling — from the workspace root, as a bounded
confined one-shot, **when the build lane settles Clean and the observer's
stream has moved — diagnostic or progress — past the last run's mark**
(`Instance.activity` is the generation; the diagnostic stream alone cannot
witness a clean-to-clean rebuild, which is the lane's most common case).
The trigger is the whole design: litany reads `.cmt` files, so linting an
uncompiled tree is meaningless — the green settle is the moment the
artifacts it reads are guaranteed fresh, which is the job the earlier
alias-rule design (`(deps (alias_rec check))`) existed to do; with the
trigger doing it, the alias and the lint rule drop out of the build graph
entirely. Lint-after-green also self-debounces: one run per green settle,
however many saves produced it, one runner in flight, a settle mid-run
re-arming it.

**The gate** mirrors the watch's ladder, in both worlds a project keeps
its linter in: the dune lane must be live at all (the trigger is the
observer's readings — a foreign watch's green settle is as good as our
own), the command non-empty (`[]` disables), and the command reachable —
directly when its program resolves on the sealed child PATH (the opam
world; no dune in the lint path), through a `dune exec` prefix otherwise
(the dune-pkg world: a dev-dependency's binary lives in the lock universe,
not on any PATH, and may need building — which `dune exec` also answers).
Either way resolution goes through the project's own environment, so the
linter found is version-matched to the compiler that wrote the artifacts
it reads. Whether the reached command exists is the first run's answer,
never a parse of anything: a structurally absent direct program, or dune's
own `Program 'name' not found` answer, takes the lane off for the session
— off is lint-absent, never lint-clean, and never a fossil of the last
word. A missing linter is a normal state (`mentat doctor` owns the
reason); one installed mid-session takes effect next session.

**Parsing.** The run's output is parsed with `ocamlc-loc` — the library
dune itself parses compiler output with, already in the lock as dune-rpc's
dependency — into findings with `Lane.Lint`: structured location, severity,
message (a rule name survives where the linter prints it in the message
tail, as litany does; the parsed header name is not kept). No marker, no convention, and **no
litany change**: litany's output only has to stay compiler-shaped, which
it is by design. Paths resolve workspace-relative exactly as stream
diagnostics do. The findings join the same law, the same reading, the same
drain — RFC 0011 §6 admits no second intake — through the shared instance
(`Instance.set_lint`), so the row's lint count and the drain's notices read
one source of truth. A run that exits zero or carries findings publishes
them (`Some []` is lint-clean, statable); a run that fails without
findings is a crashed linter and the lane keeps its last word — a crash
must never state `Lint clean`.

This repository will dogfood with litany as a dev dependency — a git
source (litany is not on opam), constrained to OCaml ≥ 5.5 < 5.6,
relocking `dune.lock` — no stanza required; the relock is the
maintainer's, still owed, and M7 gates the wall time.

## 6. Filesystem changes

The lane's mechanism is unchanged: one polling watcher pulled on the driver
fiber at claim open, claim close, and drain (`bin/workspace_watch.mli`); the
claim-window diff is `Tool_observed` evidence, externals coalesce into one
info notice; `_build` — hence `.sync` and `.rpc` — stays ignored, so the
watch's own churn never reaches the model. One change: the merged drain
orders **fswatch → dune → lint**, cause before consequence
(`bin/composition.ml:2019-2024`, a swap). Native backends stay dormant:
consumption is pull-only and nothing off-turn consumes events.

## 7. The lock-taking one-shots

All three go through dune's `go_with_rpc_server → Server.create →
Global_lock.lock_exn` and fail beside any watch.

| tool | disposition |
|---|---|
| `ocaml_dune_describe` | **Deleted** — the tool (`lib/tools/ocaml/dune_describe.*`), its expect suite (`test/tools/test_tools_ocaml_dune_describe_expect.ml`), `lib/tools/output/ocaml/project.mli`, and its arms in `tool_distill.ml:37,373`, `argument.ml:164`, `catalog-and-boot.t`, `test_tools_dependency_laws.ml`, `test_tools_output.ml`. `Mentat_ocaml_dune_describe`'s pure normalizers stay for docs. `prompts/skills/ocaml-dune.md:148,279-283` stop recommending `dune describe`; `TODO.md:6` is removed. Re-entry when dune serves describe over RPC. |
| `ocaml_docs` — `dune describe workspace` | The resolved universe is **cached on the observer's activity generation** — the lint trigger's own build witness: while no build event has flowed, repeated name queries reuse it and take no lock at all, so a burst of queries costs one describe and at most one watch pause (blind spot: the shared sub-sample one; no witness, no caching). A stale universe is **Leased** past our own watch: the supervisor pauses the child (SIGTERM, daemon-scale grace), the one-shot runs where it was, and the machine respawns through the ordinary probe-first cycle — a one-shot still winding down is discovered, never fought. Leases nest; shutdown overrides a lost one. Only a **foreign** watch — not ours to pause — still earns the honest refusal for name queries: `another session's build watch holds dune's build lock…`; path queries never consult the lease. |
| `ocaml_eval` — `dune ocaml top .` | Same lease, same foreign-only refusal. Never dune's "delete `_build/.lock`" text. |

The refusal fires beside a **foreign** watch only — the common lock holder
is the user's own terminal `dune build -w`, not ours to pause, and its
death by dune's delete-the-lock advice would be the costlier one. Our own
watch is never a refusal: the lease pauses it instead.

The prompt's OCaml tooling section gains one sentence: *when a build watch
is running (the dune status row), `dune build/test/exec/fmt/promote` forward
to it; a "Connection terminated" or "Build via RPC failed" error means it
restarted — run the command again; never delete `_build/.lock`.* The
conditional lead exists because the watch is not unconditional
(off/observe/untrusted/no-dune/gave-up); the last clause because dune's lock
message literally suggests the deletion.

## 8. Engine, protocol, UI

**Engine: nothing changes.** `drain_notices`, the three drain sites
(`driver.ml:645,1013`), `Notice.t`, `Progress.Notice`,
`Event.Workspace_notice`, replay, `render_notices` — untouched. The producer
got readings instead of guesses.

**The wire type** (`Mentat_workspace.Health` reshaped; the machine in §2 uses
these constructors):

```ocaml
type verdict = Clean | Failing of { errors : int; warnings : int }
type reading = { build : verdict; lint : int option }   (* lint = None: lane off *)
type owner   = Ours | Theirs of int
type phase   = Building | Settled of reading
type off     = Disabled | No_dune | No_server | Blocked of string | Gave_up
type t = Off of off | Probing | Starting | Live of { owner : owner; phase : phase }
       | Restarting of (Exited of string | Hung)
```

A verdict exists only inside `Settled`, so the fail-honest law is the type:
`Off × verdict` is not representable. Every phase has a producer: an owned
watch that hangs is restarted (`Restarting Hung`), and a foreign hang is not
detected — so no `Unresponsive` state exists to render; if foreign-hang
detection ever pays its way, it mints that phase alongside itself (§11).
Every restart blanks the user's verdict while `stated` keeps the
model's — intended: the row shows what is known now.

**Two queries, one fact each.** `workspace.glance` is the worktree summary
alone; `workspace.dune : unit -> Health.t` is the row's one wire carrier — a
memory read of the shared snapshot, no git involved. The TUI issues both at
the event moments and polls `workspace.dune` alone every 2 s while a watch
is live or coming up — a settled row must still follow an editor save
between turns, where no engine boundary fires. One writer per fact is
structural: the health rides exactly one endpoint. (An earlier shape kept
the glance as a pair to save a call per glance moment; the shipped TUI made
both calls anyway, so the pair was one fact with two carriers held apart by
discipline comments — deleted while the Health wire was already breaking.) A turn-less `Progress` pulse is not built:
`Progress.turn` is total (`progress.mli:124-129`), the transcript refuses
notices without an active turn (`turn.ml:798-801`), and a build that settles
between turns is stated at the next turn's preparation — the replay-faithful
moment.

**Side pane row** (`Workspace_glance.tooling`; one row, muted `dune`):

| state | row |
|---|---|
| `Probing` / `Starting` | `dune · starting` |
| `Live {_, Building}` | `dune · building` |
| `Live {Ours, Settled {Clean; None}}` | `dune · clean` |
| `Live {Ours, Settled {Failing {errors=3}}}` | `dune · 3 errors` (error colour) |
| `Live {Ours, Settled {Failing {errors=0; warnings=2}}}` | `dune · 2 warnings` (warning colour) |
| `Live {Ours, Settled {Clean; Some 2}}` | `dune · clean · 2 lint` (lint in warning colour) |
| `Live {Theirs 4242, phase}` | as above with `theirs ·` prefix |
| `Restarting (Exited "1")` / `(Hung)` | `dune · restarting (exit 1)` / `dune · hung · restarting` |
| `Off No_dune` | `dune · off · not on PATH` |
| `Off No_server` (observe) | `dune · off · no watch` |
| `Off (Blocked _)` | `dune · off · sandboxed watcher` |
| `Off Gave_up` | `dune · off · gave up` |
| `Off Disabled` | no row |

The footer keeps its ruling (`footer.mli:8-13`): no room at 80 columns; the
side pane is the status surface. Transcript rendering is unchanged. One
palette entry, `/dune`, taking `restart` or `stop` as its argument.

## 9. Config

| knob | fate | default |
|---|---|---|
| `workspace.tooling` | survives; the master gate | `auto` |
| `notices.dune_build` | **deleted** — declared, never read (`mentat_config.ml:819,885`) | — |
| `dune.watch` | **added**: `auto` probe-attach-or-spawn; `observe` attach only, never spawn; `off`. Env `MENTAT_DUNE_WATCH`; a read-only sandbox posture demotes `auto` to `observe` | `auto` |
| `dune.targets` | **added**: the watch's own targets, validated as targets — a leading dash is refused at decode; an empty list is dune's `@default` | `["@check"]` |
| `dune.lint_command` | **added**: the linter argv the runner executes after each green settle; `[]` disables; a program that does not resolve on the sealed PATH leaves the lane off | `["litany", "check"]` |
| `notices.dune_diagnostics` | survives: build-lane notices (the row still shows) | `true` |
| `notices.fswatch`, `notices.cr_comments` | untouched | `true` |

Probe bound, quiet windows, respawn delay, give-up rule, tick, body cap: one
derived constant `B` (§3) and stated derivations — not knobs.

## 10. Laws

- **L1 (the watch is confined).** A `Command.start_session` child under the
  agent's sealed policy — RFC 0009 L1's boundary, RFC 0021 L3's environment —
  never an escalated or raw spawn. *Prevents:* a `dune` file the model writes
  executing unconfined at file-watcher latency.
- **L2 (readings are the stream at rest).** The store is dune's own event
  fold; a reading exists only at quiet with no build in progress, and a
  recovery only with a witnessed settle (or the 2 s fallback). *Prevents:*
  the clear-then-republish false recovery, and a rebuild shorter than dune's
  0.2 s progress sample going unstated.
- **L3 (identity is content, not position).** Change is decided on
  `(lane, severity, path, head)` sets. *Prevents:* fresh dune ids and line
  shifts re-noticing the same error; count-only changes going unstated.
- **L4 (lost visibility never moves the baseline).** No reading ⇒ nothing
  stated, nothing forgotten; a restart settling on the stated set is silent —
  the producer-side twin of the fail-honest law (`health.mli`). *Prevents:*
  an outage fabricating a recovery.
- **L5 (the driver never waits on the world).** `drain` is a memory read and
  a pure function; every request, spawn, probe, and backoff lives on the
  supervisor fiber under a bound — the `drain_notices` contract
  (`ports.mli:335-347`) met by construction. *Prevents:* a hung or restarting
  watch stalling a tool settlement.
- **L6 (liveness is a completed request at rest).** `Hung` is declared only
  by bounded `flush_file_watcher` timeouts counted while no build or file
  event was in flight. *Prevents:* `ping`-green hangs; restarting on a slow
  build or under file churn.
- **L7 (a foreign watch is never signalled).** *Prevents:* Mentat killing the
  user's terminal session.

## 11. Drawbacks

The registry mirror is a second writer of a file dune expects to own; a dune
that starts validating registry authorship breaks it — though the blast
radius is editor discovery alone, since the agent's own readings ride the
supervisor's pinned endpoint, never the registry.

The macOS FSEvents admission is profile-wide: every confined command may
open an event stream through the `com.apple.FSEvents` mach service, and
event payloads carry path names and flags — so the names and timing of
changes may be observable past the read scope; whether fseventsd filters
delivery to it is not established. Accepted because the watch must run under
the one sealed policy and per-command policy mutation is what the
ordered-policy law forbids; scoping the allowance to the watch's own spawn
would be a policy-vocabulary change through the verified kernel surface, and
stays future narrowing.

The session-run grant is a hole punched through the `.mentat` carveout for
every confined command, not only the watch: whenever `.mentat` exists as a
real owned directory, `.mentat/run` is materialized under the owned-path
guard (lexical, `lstat`-checked, failing resolution closed on a planted
symlink — a tracked `.mentat/run -> ~/.ssh` must never become a host write
grant) and granted writable. Its content is read by nobody — entries are
counted, never parsed, and cleared before each spawn — so cross-command
scribbling can shift timing, not content. The lint runner's parser
(`ocamlc-loc`) is version-pinned but marked unstable by dune upstream; a
format change surfaces as unparsed lint output, never as misfiled build
findings — the lanes cannot cross by construction. The runner's trigger
rides the same sampled stream as recovery: a sub-sample clean-to-clean
rebuild folds no event, so that settle can go unlinted — and a fixed lint
finding outlive its fix — until the next observed build; a reconnect's
sync events buy one redundant, idempotent run; and in the dune-exec world
a run's own forwarded no-op build can advance the stream and buy an echo
run, bounded by the poll and the run's own duration. The recovery fallback leaves a residual: dune samples build
state every 0.2 s, so a failing rebuild whose events are delayed beyond the
2 s quiet window can state a recovery the next settle retracts — inherent to
the sampled stream, uncloseable from a client. The socket and lock live in
the agent-writable build directory: an agent that replaces
`_build/.rpc/dune` controls what the row and the notices say — the row is
evidence about the agent's workspace, not a check on the agent (a peer-pid
check is §15). Deleting describe removes capability the model had; any
future policy narrowing must keep `.mentat/run` writable or the watch dies at
startup. A hung foreign watch is indistinguishable from a busy one: the
observer never probes a watch it may not restart, so the health vocabulary
has no state for it — the row reads `building` until the foreign watch
answers or its connection drops to `Probing`. Detection (a bounded foreign
flush on tool-timeout evidence) would mint the state it announces.

## 12. Rationale and alternatives

- **Passive watch mode, Mentat as the loop** — exact lane attribution by
  request and a hang bound on Mentat's own requests; loses because the
  editor's save triggers nothing, Mentat re-implements dune's trigger and
  debounce, and the lane split costs one litany line instead.
- **Keep the per-drain one-shot probe, only add a spawner** — the smallest
  diff; loses on L2 (the 15 s guess survives) and L5 (a connection per drain
  on the driver fiber).
- **The one-shot `diagnostics` request at settle** (an earlier draft) — loses
  to the event fold: the progress stream is sampled, so "settled" cannot be
  ordered against a request; the diagnostic stream orders itself.
- **A synthetic build probe** — cancels and restarts running builds under the
  nightly, and its bound is the rebuild's duration (§3).
- **A lease linger** (hold the watch down briefly after a release so
  consecutive one-shots share one bounce) — loses to the universe cache: the
  linger speculates on a next call with a magic duration and keeps the watch
  down when none comes, while the cache removes the repeat calls' need for
  the lock entirely; and eval, whose runs are long, never needed either. Can
  be added later without a wire change if real bursts of lock-takers outrun
  the cache.
- **Separate build dir** (`TODO.md:6`) — the agent's `dune build` then takes
  the free `_build/.lock` and runs a second cold build: double CPU, two rule
  graphs, `.merlin-conf` from whichever built last, notices about a build the
  agent never ran; and in a dune-package project a fresh dir has no
  `_private/default/.pkg`, so even describe would first build every
  dependency. Its one beneficiary is deleted anyway.
- **Other litany lanes** — the default lane spawns `dune describe` (lock);
  `--units` needs a roster captured with the server stopped; `--cmt-root` is
  a second freshness engine racing the watch, project rules withheld; a
  Mentat-side `--format json` process is a second channel with a second
  dedup.
- **Lint inside the watch, lanes split by a message-text marker** — the
  original §5: `@<alias>` among the watch's targets, findings classified by
  a ` [rule]` suffix litany would gain upstream. Rejected: the marker was
  load-bearing (a build error ending in ` [word]` misfiled), it demanded a
  litany release, it ran lint on every save instead of every green, and the
  watch's own verdict went permanently red whenever findings existed.
- **Lint as a `dune build @lint` one-shot after green** — the intermediate
  shape: forwarding beside a watch is isolated (a forwarded build's
  failures are answered to the requester, never folded into the shared
  diagnostic set — verified live against the nightly, both directions), so
  the lanes separate by source. Rejected for the simpler truth underneath:
  the alias's one real job was artifact freshness, and the green-settle
  trigger already guarantees it — so the linter can just run, with no
  alias contract, no alias-undefined detection, and no dune in the loop.
- **Lane by severity** (Warning ⇒ lint) — misclassifies non-fatal compiler
  warnings printed beside an error.
- **Lane by the diagnostic's `directory`** — narrower than severity but still
  a heuristic that sometimes lies; an honest absence beats it.
- **Admitting the real registry directory** — makes a global unvalidated
  store agent-writable and, under `--unshare-pid`, registers every watch as
  the same namespace pid; the private-dir-plus-mirror keeps both properties.
- **Turn-less `Progress` for the status** — breaks `Progress.turn`'s totality
  for a UI fact the executable already owns.
- **Prior art.** ocaml-lsp: two long-polls on one client, settle on progress,
  content dedup at publish — and it wipes diagnostics on disconnect, which L4
  inverts. rust-analyzer: publish only on `DidFinish`; dedup by
  `(range, severity, code, message)`. Claude Code: file-change reminders
  scoped to files the model read, ephemeral; Mentat's are durable, turn-scoped
  facts.

## 13. Cost, slices, kill criteria

Sizes are measured against comparables (the supervisor against
`Session`+`shell/registry.ml`; the fake against today's 199-line server; the
cram against `fswatch.t`'s 30 lines/scenario), not hoped.

| slice | content | ≈ lines | seam / gate |
|---|---|---|---|
| A · attach + settle + law + status | persistent connection, two long-polls, store fold, overtake/quiet rules (`rpc.ml` +300); `Finding`/`Reading`/`Change` with `.mli`s (+250); producer render in `bin/` (`workspace_notices.*` rewritten in place); `Health` reshape + `workspace.dune` query + row + tick (+250); concurrent fake with scripted timeline (+250); cram + unit + goldens (+390) | ≈ +1,560 / −250 | **no spawn**: runs against any registered watch — the maintainer's own `dune build -w` — and already retires the 15 s guess, the head-string law, and the per-drain probe. Deleted outright: `Instance.build_health`, `Instance.Health`, the diagnostic store surface, and the glance's producer+mapping; `bin/workspace_notices.*` is rewritten to the drain producer alone. |
| B · own it | `bin/dune_watch.{ml,mli}` supervisor (~650 with docs), lazy spawn via `start_session`, probe-before-spawn, private `XDG_RUNTIME_DIR` + host mirror, stop-before-release; describe deleted (−1,780 incl. suite and ripple); docs/eval refusals (+80); skill/prompt text; `dune.watch`/`dune.targets` | ≈ +900 / −1,800 | first deliverable is the confinement spike: FSEvents under seatbelt (statically, no `mach-lookup` for `com.apple.FSEvents` is allowed — the allowance line, profile-wide per §11, is the deliverable), registry write under the private dir, socket from a confined child; the §3 self-test backs it at runtime |
| C · hang | dune-command tool timeout → stall report → one verification flush → restart; first-flush confinement self-test; `dune.watch` notice; `MENTAT_DUNE_WATCH_FLUSH_S`; fake `hang`/`slow`/`hang-flush` mode directives | ≈ +230 | after B; insurance (the hang was old-dune); no periodic probe — the evidence path pays only on evidence |
| D · lint | the green-settle runner (bounded confined one-shot, no dune in the loop), `ocamlc-loc` parse into the lint lane, `dune.lint_command` knob with the watch-shaped availability gate; classifier and marker convention deleted; no litany change; the dogfood dev dep landed with the maintainer's relock (litany is a with-test dependency of this repository) | ≈ +300 / −150 | after B (rides the instance); no upstream work |
| E · commands + lease | `/dune restart|stop` (one `workspace.dune_control` endpoint, the row refreshed from the verb's answer), doctor's `dune` and `lint` rows (posture, reachability, and the off reasons), the watch lease (pause/park/resume on the supervisor, `Leased/Held/Free` at the tools' lock moment) | ≈ +350 | after B; the Leased bracket's release is pinned by tool expects on both run outcomes; the pause/park/respawn machine rides the QA script — a hermetic lease cram needs a real one-shot beside a fake watch and is deliberately unpinned |

**Sequencing.** A ships alone and is useful alone, with no sandbox question
and nothing new holding the lock. B is not shippable without describe's
deletion and the fake `dune` executable. C and D are independent of each
other.

**Tests.** Hermetic: the fake grows into a concurrent fake `dune` executable
(long-polls stay open while other requests answer; lock, socket, private
registry, scripted timeline; `--hang-flush`, `--exit-after`, a second
instance already serving the socket for foreign attach). Cram
`run/dune-watch.t`: failing → resolved → recovered across claims in one turn;
count-only silence; two saves inside the sample period ⇒ no `Build
recovered`; an error text changed inside the sample period ⇒ `1 new, 1
resolved`; lint-only leaves the build lane clean;
foreign attach; `dune.watch=observe`. Cram `run/dune-own.t`: a dune-command
timeout ⇒ one verification flush ⇒ restart ⇒ notice naming the cause; the
same timeout with an answering flush ⇒ no restart, no notice; a blocked
first flush ⇒ `Off Blocked`, one notice, no respawn. Cram `run/dune-lint.t`:
findings on green, own lane, build lane clean; one run per green settle
(the argv count across red-green cycles); a crashed run keeps the stated
findings and never states `Lint clean`; a completed clean run earns it; a
foreign watch's green settle triggers the runner with no spawn of ours;
the dune-exec reach with the lock-universe bin; the not-found answer
taking the lane off after exactly one run. Deliberately unpinned (known,
not owed yet): the activity-cleared verification, the `No_server` verdict,
the dropped-report paths (observe, foreign, between lives), the
`Restarting Hung`/`Off Blocked` row renders — the TUI story below owes the
rows — the lease machine's park/respawn arcs and the `/dune` verbs end to
end (the codec arms, the doctor rows, and the release bracket are pinned;
the verb-to-row ride is owed with the TUI story), and, for the lint lane: re-arm mid-run (timing-fragile by nature),
the 600 s run bound (no scaling env until a test wants it), the
transient-launch-failure keep, and the signal-death keep. Unit: `Change.step` properties (idempotence, range and
count invariance, lane independence, recovery confirmation, no-reading
identity). TUI: one pty story through the row states plus the notice goldens.
Live-gated: a real watch on a fixture with a shell `lint` rule; no stall
report is ever raised during a cold build of this repository (no dune tool
timeout ⇒ no flush); a forwarded build from a confined child. A QA script on this repository drives every §8 row
and every §4 notice, ending with quit → no orphan, no socket, no mirror.

**Success and kill criteria** (M1–M7; the supervisor logs one line per
settled reading, `dune.reading lane=… n=… digest=… stated=…` — readings are
derived state, logged, never persisted; notices are already journaled):

- M1 precision: notices with `digest = stated` = 0 over a week of the
  maintainer's sessions. M2 missed transitions: readings with
  `digest ≠ stated` and no notice at the next drain = 0.
- M3: the watch notices name the restart's cause (keys `dune.watch.hung` /
  `dune.watch.blocked`); the journal count is a lower bound — a hang on a
  session's last claim never drains — with the `mentat.dune.watch` warn
  line as the reconciling record. If two release cycles journal zero hang
  restarts, slice C's stall machinery is deleted and only the first-flush
  self-test stays.
- M4 spawn → first settle, logged; warm p50 > 60 s ⇒ revisit `@check`/lazy.
- M5 daemon CPU with the TUI attached during a build < 2 %, else the tick
  slows. M6 no-op iteration p50 (informs any future build probe). M7 lint
  wall time per `.cmt` change on this repo > 5 s ⇒ the dogfood stanza is
  scoped or off in watch.

## 14. Questions the campaign resolved

**Q1 — pin litany into Mentat so it always lints? No.** (i) Litany supports
one compiler minor and refuses foreign `.cmt`s naming both versions
(`litany/README.md`): a litany welded to Mentat's 5.5 refuses every 5.4/5.6
project on every build. (ii) Mentat is one static binary; a pin in its lock
installs a litany into Mentat's `_build`, invisible to the user's dune
resolving `(run litany check)` on *its* PATH. (iii) Dune has no external rule
injection; a dependency delivers no stanza. (iv) The linter is the project's
tool, like ocamlformat; the contract Mentat integrates with is "a command
printing the toolchain's diagnostic grammar", litany is one implementation
(the default, not a coupling), and the "always available" home is dune's
closed dev-tool list, upstream (`_ref/dune/src/dune_pkg/dev_tool.ml`). What
"Mentat always lints" honestly means: light the lane when the command
resolves, say why in `mentat doctor` when it does not, and dogfood in this
repository (§5).

**Q2 — which dune exhibited the hang?** An old one — the maintainer had not
run watch mode recently, and the nightly rewrote the loop the audited
mechanisms lived in. Slice C is insurance, shaped behaviourally so it holds
on any version.

## 14b. Still open

**Before merge.** *(a)* Accept the litany one-line marker change upstream
(gates slice D's lane split). *(b)* The `dune.targets` default — `@check` is
argued in §2; confirm against daily use on this repository.
**During implementation.** Eval/docs lease shape (pause-respawn vs
per-call); whether the mirror should also serve `dune rpc status --all` or
only ocaml-lsp; whether the change law's stated baseline should be rebuilt
from the journaled dune notices at session resume — today it restarts empty,
so a resumed session re-states a still-failing set as new, the safer of the
two dishonesties; litany's result cache under the confined watch —
`~/.cache/litany` is not an admitted root, so the in-build lane recomputes
per run unless it is admitted (one carveout, same class as `~/.cache/dune`)
or the stanza passes `--cache-dir` — M7 measures which.
**Out of scope.** Stale-write refusal in the edit tool.

## 15. Future possibilities

A `describe` procedure over dune RPC restores the tool; a dune `Diagnostic`
generation carrying the warning code and rule name (the lexer already has
both) makes the marker unnecessary; a socket peer-pid check
(`LOCAL_PEERPID`/`SO_PEERCRED`) authenticates readings; a turn-less
`Progress` pulse if the web edge
wants push; eval's directives synthesized from `dune ocaml-merlin` so it
never needs the lock.

*The anti-ratchet rule: something appearing here is never a reason to accept
this or a later RFC.*
