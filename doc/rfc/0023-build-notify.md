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
   Lint findings travel the same wire, split by a marker litany prints.
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
said while the set is unchanged, however many rebuilds happen. If the project
defines a `lint` alias that runs litany, findings arrive the same way:

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
- [warning] dune: Build watch restarted (flush probe timed out)
A dune command that was running may have failed with "Connection terminated"
or "Build via RPC failed"; run it again.
```

If you already run your own `dune build -w`, Mentat attaches to it: the row
reads `dune · theirs · clean` and notices come from your watch. Stop yours
and Mentat starts its own.

## 2. The watch: ownership, route, lifecycle

**Argv and mode.** `<dune> build --root . --watch <targets>`, `dune` resolved
as the tools resolve it (`Tool_boot.resolve_program`,
`bin/composition.ml:1857`), cwd the workspace root. Targets: `dune.targets`
(default `["@check"]`) plus `@<dune.lint_alias>` when §5's probe finds the
alias — `@check`, not `@default` or `@all`, because it is what merlin,
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
`XDG_RUNTIME_DIR=<root>/.mentat/run/<session>` — inside the Write root, read
by nobody else — and Mentat **mirrors** the entry into the user's real
registry host-side, unconfined, with `pid = Session.pid` (the host pid) and
the socket path, unlinking the mirror on every exit path. ocaml-lsp discovers
the mirror; the agent can touch neither the real registry nor another
project's. Mentat's own foreign-mode picker additionally rejects entries
whose pid is not a process it can signal-0 without `EPERM`-only evidence.

**Discovery.** Mentat knows its watch's pid and socket; it never polls the
registry for its own watch. Registry discovery (`rpc.ml:583-624`) survives
for foreign attach only.

**Lifecycle.** The supervisor is created once per instance in `make_instance`
(`bin/composition.ml:275`) under the instance switch — `build_execution_layer`
takes it by reference, so the `tui_capabilities` and `tool_declarations`
projections (`:2747,2755`) never spawn. It spawns **lazily, at the first
turn's preparation** — never at daemon boot, so opening a TUI on a cold
monorepo does not start a build, and `mentat run`/cram one-shots spawn only
when a turn actually drains. Stop is `Session.signal` (SIGTERM to the group,
grace, SIGKILL) issued before the switch releases, so dune's `at_exit`
unlinks its socket and private registry entry; the switch's own release —
Eio's child-only SIGKILL (`mentat_workspace_io.mli:598-603`) — is the
backstop, and the mirror is unlinked host-side either way.

**The machine** (one vocabulary, shared with the wire type in §8):

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

Under `dune.watch = observe` the no-server arc is
`Probing ─no server─▶ Off No_server`, re-probed every `B`; only `auto`
proceeds to `Starting`. A dune that does not resolve at all is
`Off No_dune` before any probe. The foreign pid is the registry entry whose
`where` is the answering socket, else the `_build/.lock` contents.

The pre-spawn **probe** exists because a spawned `dune build --watch` under a
held lock does not fail: it forwards one build to the holder and exits 0/1
(`_ref/dune/bin/build.ml:173-204` — the watch flag is consulted only in the
lock-acquired branch), so the lock message never reaches a supervisor.
Probing connects to `<root>/_build/.rpc/dune` and initializes; an answering
server means **foreign attach**: the same readings run against it, the row
says `theirs`, and it is never signalled (L7). A watch that reached `Live`
resets the give-up counter; `Off Gave_up` is left by `/dune restart` or the
next session.

## 3. Hang detection

The observed hang belongs to the old build loop (the maintainer confirms an
old dune; the nightly rewrote the loop and merges RPC requests into the
running build), so mitigation here is insurance, and detection is
behavioural — a bounded request that must complete — never a claim about a
code path. `ping` is never the signal: it is `fun _ -> Fiber.return`
(`_ref/dune/src/dune_rpc_impl/server.ml:248`).

**One probe.** A bounded `flush_file_watcher` request every `B = 10 s` while
`Live {Ours}`: the public procedure that waits for the file watcher's sync
round-trip and the debounce quiet period (`build_loop.mli:28-31`) — it
exercises dune's event loop and never waits on the build. A timeout **counts
only if no progress or diagnostic event arrived during the probe's window**
(file churn legitimately extends the debounce); each completed probe resets
the counter. `Hung` after two consecutive counted timeouts; then
`Session.signal`, `Restarting Hung`, respawn. The model's in-flight forwarded
build fails with a dune RPC error — `Connection terminated …` on a killed
watch, or `Build via RPC failed, but the RPC server did not send an error
message` when the session closed first — and the drain that follows that
tool's settlement carries the `dune.watch` notice naming the probe (§1), so
the journal can count restarts by kind. A false positive costs one
incremental restart and at most one failed agent build with an explicit retry
message.

`B` derives: `2B` is a third of the shell tool's default timeout, so a
blocked forwarded build is released by the restart well inside it, and `B` is
100× dune's 0.1 s debounce. Test-only env scaling, never §9 knobs:
`MENTAT_DUNE_WATCH_PROBE_S` for `B`, and `MENTAT_DUNE_RPC_QUIET_S`,
`MENTAT_DUNE_RPC_QUIET_FALLBACK_S`, `MENTAT_DUNE_RPC_RECONNECT_S` for the
reading windows a hermetic fake cannot wait out.
The **first** flush after `Live {Ours}` doubles as the confinement self-test:
if it never completes on a fresh watch, the state is
`Off (Blocked "file watcher blocked by the sandbox")` at once — no restart
budget spent, one warning notice naming the seatbelt allowance (§13 slice B).

A synthetic *build* probe is deliberately absent: under the nightly a build
request cancels and restarts a running build, and its completion time is the
whole rebuild's — a probe that either disturbs the loop or times out on slow
builds. The agent's own forwarded builds already traverse the exact path that
can hang, bounded by the shell tool's timeout; wiring that timeout to the
supervisor as a stall report is a Future gated on evidence (§13 M3).

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

**Lanes.** A diagnostic is `Lint` iff its first message line ends with
` [<rule>]`, `<rule>` matching `[a-z][a-z0-9-]*`, and either Mentat's watch
requested `@<dune.lint_alias>` or the watch is foreign (whose targets are
unknown). Dune's parser drops the warning code and rule name before RPC
(`exported_types.ml:767-773`; the lexer had both, `ocamlc-loc/src/
lexer.mll:72-78`), so the marker must live in the message text; litany's
error lines already carry it there (`Error: <msg> [rule]`). The litany change
shipping with the lint slice makes warnings match: the header's bracketed
name — which dune's grammar requires but discards before RPC — becomes the
constant `[litany]`, and the rule moves to the message tail, once:
`Warning 0 [litany]: comparison through List.length is a needless emptiness
test [needless-list-length]` (`litany/lib/render.ml:196-200`). The marker is
compiler-compatible by construction (free message text after a well-formed
header), warnings and errors become consistent, and — since dune drops the
header name — editors gain over RPC the rule name they currently lose
entirely. A bracketless `Warning 0:` header was rejected: dune's lexer has no
such arm and the whole block would fall back to one unparsed diagnostic. Until then the lane is off and lint findings are build-lane warnings.
Under a foreign watch `lint = None` unless a marker-bearing finding is
present — targets unknown means lint-absent, not lint-clean, so a foreign
watch never states `Lint clean`.
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
frozen and silent; dropping the alias deliberately (stanza removed,
`dune.lint_alias = ""`) resets `stated.lint` to ∅ silently, so findings that
return with the alias are `new`. A watch `Off` for an hour that settles on
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

The lane is the in-build rule over dune RPC, and nothing else:

```lisp
(rule (alias lint) (deps (alias_rec check)) (action (run litany check)))
```

(`litany/doc/manual/build-integration.md`). Dune is the freshness engine —
the rule re-runs exactly when a `.cmt` changed — litany prints dune's grammar
and exits 1, each `File` block becomes one `Warning` diagnostic, and lint
enters the same set, the same law, the same drain — RFC 0011 §6 admits no
second intake. The alternatives are in §12.

**Alias presence.** Before each spawn the supervisor parses the workspace's
`dune` files as s-expressions (comments stripped) and requests
`@<dune.lint_alias>` iff a `rule` stanza carries `(alias <name>)`/`(aliases …
<name> …)` or an `alias` stanza defines it — a match in a `deps` field is a
use, not a definition. Generated and OCaml-syntax `dune` files are not seen:
`mentat doctor` says `lint alias: not found in static dune files`, and a
trailing `!` on `dune.lint_alias` forces the target. The backstop is the
error itself: a loc-less diagnostic beginning `Alias "lint" specified on the
command line is empty` drops the target and respawns once. Adding the stanza
mid-session takes effect on `/dune restart` or the next session.

This repository dogfoods: the stanza plus litany as a dev dependency — a git
source (litany is not on opam), constrained to OCaml ≥ 5.5 < 5.6, relocking
`dune.lock`; the rule lints the whole workspace on every `.cmt` change, which
M7 gates.

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
| `ocaml_docs` — `dune describe workspace` (`docs.ml:1853-1866`) | **Honest refusal** for name queries while a watch holds the lock: `the docs universe needs dune describe, which cannot run beside the build watch; use ocaml_find_definitions/ocaml_type_at`. Path queries are unaffected. The lease (slice E) serves it. |
| `ocaml_eval` — `dune ocaml top .` (`eval.ml:406-415`) | Same refusal, same lease. Never dune's "delete `_build/.lock`" text. |

The prompt's OCaml tooling section gains one sentence: *Mentat runs
`dune build --watch`; `dune build/test/exec/fmt/promote` forward to it; a
"Connection terminated" or "Build via RPC failed" error means it restarted —
run the command again; never delete `_build/.lock`.* The last clause exists
because dune's lock message literally suggests it.

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
type phase   = Building | Settled of reading | Unresponsive
type off     = Disabled | No_dune | No_server | Blocked of string | Gave_up
type t = Off of off | Probing | Starting | Live of { owner : owner; phase : phase }
       | Restarting of (Exited of string | Hung)
```

A verdict exists only inside `Settled`, so the fail-honest law is the type:
`Live {Theirs _; Unresponsive}` is representable (a foreign watch Mentat may
not restart), `Off × verdict` is not. `Unresponsive` is reachable only under
`Theirs` — an owned watch is restarted instead (`Restarting Hung`) and never
renders it. Every restart blanks the user's verdict while `stated` keeps the
model's — intended: the row shows what is known now.

**Two queries.** `workspace.glance` keeps its pair — stripping it would
force two calls at every glance moment — but its dune half becomes a free
projection of the shared snapshot, and its handler stops building a second
producer and draining it on read. The status-only `workspace.dune : unit ->
Health.t` is the same observation without the git read; the TUI issues both
at the event moments and polls `workspace.dune` alone every 2 s while a
watch is live or coming up — a settled row must still follow an editor save
between turns, where no engine boundary fires. Each fact has one writer: the
glance never feeds the row. A turn-less `Progress` pulse is not built:
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
| `Live {Theirs 4242, phase}` | as above with `theirs ·` prefix; `dune · theirs · unresponsive` |
| `Restarting (Exited "1")` / `(Hung)` | `dune · restarting (exit 1)` / `dune · hung · restarting` |
| `Off No_dune` | `dune · off · not on PATH` |
| `Off No_server` (observe) | `dune · off · no watch` |
| `Off (Blocked _)` | `dune · off · sandboxed watcher` |
| `Off Gave_up` | `dune · off · gave up` |
| `Off Disabled` | no row |

The footer keeps its ruling (`footer.mli:8-13`): no room at 80 columns; the
side pane is the status surface. Transcript rendering is unchanged. Two
palette commands, `/dune restart` and `/dune stop`.

## 9. Config

| knob | fate | default |
|---|---|---|
| `workspace.tooling` | survives; the master gate | `auto` |
| `notices.dune_build` | **deleted** — declared, never read (`mentat_config.ml:819,885`) | — |
| `dune.watch` | **added**: `auto` probe-attach-or-spawn; `observe` probe-attach only, never spawn; `off` | `auto` |
| `dune.targets` | **added**: the watch's own targets | `["@check"]` |
| `dune.lint_alias` | **added**: the alias whose presence lights the lint lane; `""` disables; trailing `!` forces | `"lint"` |
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
that starts validating registry authorship breaks it. The lint lane rests on
a message-text convention because the wire drops the rule name; a failing
action under `@check` whose first line happens to end in ` [word]` lands in
the lint lane. The recovery fallback leaves a residual: dune samples build
state every 0.2 s, so a failing rebuild whose events are delayed beyond the
2 s quiet window can state a recovery the next settle retracts — inherent to
the sampled stream, uncloseable from a client. The socket and lock live in
the agent-writable build directory: an agent that replaces
`_build/.rpc/dune` controls what the row and the notices say — the row is
evidence about the agent's workspace, not a check on the agent (a peer-pid
check is §15). Deleting describe removes capability the model had; any
future policy narrowing must keep `.mentat/run` writable or the watch dies at
startup.

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
- **Lane by severity** (Warning ⇒ lint) — misclassifies non-fatal compiler
  warnings printed beside an error; the marker is exact.
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
| B · own it | `bin/dune_watch.{ml,mli}` supervisor (~650 with docs), lazy spawn via `start_session`, probe-before-spawn, private `XDG_RUNTIME_DIR` + host mirror, stop-before-release; describe deleted (−1,780 incl. suite and ripple); docs/eval refusals (+80); skill/prompt text; `dune.watch`/`dune.targets` | ≈ +900 / −1,800 | first deliverable is the confinement spike: FSEvents under seatbelt (statically, no `mach-lookup` for `com.apple.FSEvents` is allowed — the allowance line is the deliverable), registry write under the private dir, socket from a confined child; the §3 self-test backs it at runtime |
| C · hang | flush probe, counters, budget, `dune.watch` notice, `MENTAT_DUNE_WATCH_PROBE_S`, fake `--hang-flush` | ≈ +300 | after B; insurance (the hang was old-dune) |
| D · lint | alias parse + backstop, marker split, litany's one-line marker (upstream), dogfood stanza + dev dep | ≈ +280 | after A; independent of B |
| E · commands + lease | `/dune restart|stop`, doctor lines, the watch lease serving docs and eval | ≈ +350 | after B |

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
resolved`; lint-only leaves the build lane clean; alias absent ⇒ no `@lint`;
foreign attach; hang ⇒ restart ⇒ notice naming the probe;
`dune.watch=observe`. Unit: `Change.step` properties (idempotence, range and
count invariance, lane independence, recovery confirmation, no-reading
identity). TUI: one pty story through the row states plus the notice goldens.
Live-gated: a real watch on a fixture with a shell `lint` rule; the flush
probe never fires during a cold build of this repository; a forwarded build
from a confined child. A QA script on this repository drives every §8 row
and every §4 notice, ending with quit → no orphan, no socket, no mirror.

**Success and kill criteria** (M1–M7; the supervisor logs one line per
settled reading, `dune.reading lane=… n=… digest=… stated=…` — readings are
derived state, logged, never persisted; notices are already journaled):

- M1 precision: notices with `digest = stated` = 0 over a week of the
  maintainer's sessions. M2 missed transitions: readings with
  `digest ≠ stated` and no notice at the next drain = 0.
- M3: `dune.watch` notices name the probe; if two release cycles journal
  zero hang restarts, slice C shrinks to restart-on-exit. The forwarded-build
  stall report ships only if M3 shows hangs the flush missed.
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
tool, like ocamlformat; the contract Mentat integrates with is "`@lint`
printing dune's grammar", litany is one implementation, and the "always
available" home is dune's closed dev-tool list, upstream
(`_ref/dune/src/dune_pkg/dev_tool.ml`). What "Mentat always lints" honestly
means: light the lane when the alias exists, say `lint alias: absent — add
the stanza` in `mentat doctor`, and dogfood in this repository (§5).

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
(`LOCAL_PEERPID`/`SO_PEERCRED`) authenticates readings; the shell-tool stall
report as a hang signal (M3); a turn-less `Progress` pulse if the web edge
wants push; eval's directives synthesized from `dune ocaml-merlin` so it
never needs the lock.

*The anti-ratchet rule: something appearing here is never a reason to accept
this or a later RFC.*
