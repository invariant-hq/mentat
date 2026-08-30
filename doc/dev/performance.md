# Performance notes

Developer reference covering the three performance regimes: the launch (to
the first frame), the render loop (steady state and streaming), and the
test suite's cost model. User-facing behavior lives in the manual
(`doc/manual/configuration.md`, "Workspace tooling"); the deterministic TUI
harness these notes lean on lives in `test/tui/harness/`. Numbers are
from 2026-07-09 on an M-class laptop (render-loop figures: 40×120 terminal,
~500 KB transcript) — treat them as budgets, not gospel.

## The launch budget

The TUI's first frame must never wait on network, TLS, subprocesses, or
directory scans. An unknown workspace first shows the plain-terminal trust
preflight; no normal app, session, or project process exists until that
choice is persisted and startup reloads. After trust is resolved, the launch
path is budgeted:

| Phase | Cost | What it is |
| --- | --- | --- |
| Boot | ~2 ms | Trust store, permitted config layers, session store, snapshot. |
| Loop bring-up | ~7 ms | Mosaic renderer/reconciler, first frame render. |
| Launch background | tens of ms, off-path | Session observe, then tooling when engaged. |

Two classes of regression have already been caught and are worth guarding
against by name:

- **Eager crypto/TLS init.** `Mirage_crypto_rng_unix.use_default` (~30 ms,
  entropy seeding) and `Ca_certs.authenticator ()` (~35 ms, parses the whole
  system CA bundle) must not run at client construction. They live behind one
  shared `lazy tls_authenticator` in `lib/provider_runtime/tls_setup.ml`, forced
  on the first TLS handshake and paid once for every TLS consumer. Keep it that
  way: constructing a client must not initialize TLS.
- **Synchronous subprocess spawns.** No subprocess may spawn on the first-frame
  path. The workspace Dune tooling (`dune describe`, `dune build --watch`,
  fswatch, Merlin) is gated by workspace trust plus `workspace.tooling`, engages
  only in trusted Dune workspaces, and runs asynchronously after the frame
  renders.

The rule behind both: **construction is free; first use pays.** Anything
observable in the first frame must come from data already on the boot path;
everything else is lazy or delivered asynchronously after the frame renders.

## Measuring the launch

The deterministic TUI harness (`test/tui/harness/`) runs the identical launch
code — the real `Mentat_tui.Runtime.run` under a headless Matrix backend — so
its boot cost is representative of the real binary's. The harness carries no
separate launch-timing instrumentation; the ~60 ms boot figure in the
test-suite cost model below is the observable span, and a settle that exceeds
its budget fails loudly rather than silently.

For the real binary, `time mentat --help` measures process overhead (dominated
by first-exec page-in of the ~44 MB binary). The TUI-specific path is best
watched through the harness, which runs the identical code, or through a pty
sample against the real binary (see "Measuring the render loop").

## The frame cost model

A dirty frame runs the full pipeline: view rebuild → reconcile → layout →
paint, over the **entire mounted tree**. There is no partial pass; cost is
O(mounted content). At ~500 KB of transcript one frame is ~7 ms, so what
matters is (a) how often frames happen and (b) how much per-frame work the
view functions add on top.

| State | Frames | CPU (~500 KB transcript) |
| --- | --- | --- |
| Idle, nothing on screen changes | one per clock tick (1 s) | ~1 % |
| Streaming turn | paced to target fps (30) | ~9 % |
| Home, pour animating | live cadence (tick sub) | bounded by the stage |

Frames come from exactly three sources, and each has an owner:

- **Live cadence** — matrix renders every frame while live. Only genuine
  animation may hold this: mosaic requests it for `Sub.on_tick` alone, and
  mentat creates its matrix app with `start_idle:true` (`runtime.ml`). Without
  that flag the loop boots `Explicit_started` — permanently live — and
  re-renders the whole transcript at 30 fps forever, CPU proportional to
  session length while nothing changes.
- **One-shot redraws** — any dispatch requests one. They are paced to target
  fps off the last render time, so a delta storm coalesces instead of
  rendering back-to-back.
- **Timer wakeups** — `Sub.every` is a timer, not an animation: it arms
  `Matrix.schedule_wakeup` (an `on_frame` call with no render) and whatever
  its message changes requests its own redraw. A pending timer costs a
  wakeup, never a pipeline pass.

## Render-loop regressions, caught by name

The 2026-07 freeze report ("spinned for minutes, 100 % CPU") decomposed into
independently sufficient causes. Each teaches a law; guard them by name:

- **`take_last` recomputed `List.length` per recursion step** — O(rows²)
  per frame over the reasoning ticker's wrapped lines; the single dominant
  cost in the streaming profile. Stdlib `List.take`/`List.drop` exist (5.3+);
  hand-rolled list helpers are where accidental quadratics live.
- **`word_wrap` built `cur ^ " " ^ word` and re-measured the candidate per
  word** — O(line²) per line, every frame. The wrap now carries a reversed
  word list with a running column count (`turn.ml`); wrapping is linear or it
  is a frame-budget bug.
- **Whole-buffer work for a bounded window.** The collapsed ticker and shell
  tail show 3 rows but wrapped their entire accumulated stream per frame.
  `Turn.last_wrapped_rows` wraps only the physical-line suffix that can fill
  the window. The law: per-frame work is O(what is visible), never
  O(what has accumulated).
- **Append-grown content re-derived per frame.** Buffers that change only on
  delta but render every frame memoize on physical identity — the expanded
  ticker's wrap, and the markdown widget itself (`Props.equal` on content;
  the style and `code_syntax` values must be stable top-level definitions,
  never per-view closures, or the memo misses every frame). The
  `assistant_stable`/`assistant_open` split keeps the markdown re-parse to
  once per completed line; tree-sitter highlighting is settled-only.
- **`Sub.every` used to hold the live cadence** (fixed upstream in mosaic)
  and **the app created its matrix app without `start_idle`** — either alone
  kept the pipeline running at 30 fps forever. If idle CPU is nonzero and
  grows with session length, suspect these first.
- **`Ansi.Style.equal` went through polymorphic compare** (fixed upstream) —
  per-cell diffing made it a top-two profile leaf. Abstract types under `=`
  are generic-compare calls; hot equality is field-wise and monomorphic.

Still open, by design: the transcript mounts every settled block in one
scroll box, so a dirty frame is O(session). Windowing the document (mount
the visible tail, extend on scroll-up) needs a design pass over the viewport
contract in `lib/tui/scrollport.mli`: sticky-bottom behavior, one-shot reveals,
and preserving replay seams and scroll position while blocks mount and unmount.
Since frames now only happen on real dirt, this is a cost multiplier, not a
standing burn.

## Measuring the render loop

The freeze was found and verified with a pty repro against the real binary —
the method is worth keeping:

- Drive `bin/mentat/main.exe` in a pty (pyte) against
  `test/blackbox/bin/mentat_fake_provider_server.exe` with a large scripted
  response (~1500 fragments of reasoning + markdown) and `stream_delay_ms`
  holding the terminal SSE event, so the turn stays in flight with static
  content. Everything from SSE bytes to screen is the production path.
- Sample `%cpu` with `ps` at 2 Hz across submit → settle → idle; capture hot
  stacks with macOS `sample <pid> 5` mid-stream and post-settle. Tally by
  symbol (`grep -oE 'camlMentat_tui__Turn\$[a-z_]+'` and friends) — the freeze
  showed up as one towering symbol, not a flat profile.
- Calibration: streaming ~9 %, idle ~1 % at ~500 KB. The historical bad
  numbers, for scale: 98–100 % streaming and ~27 % idle (growing with
  transcript size) before the fixes above.

Suspects already cleared, so the next hunt doesn't re-tread them: the
markdown memo (deltas coalesce to one view pass per frame; cmarkit never
appeared in profiles), the session step loop (`max_steps`; a no-tool-call
response completes the turn), and google/SSE transport (EOF-safe reader,
bounded slept retries).

Not cleared, and worth a measurement before the next hunt: the workspace
notice drain. It runs on the driver fiber between a tool's result and the
request reporting it, once per tool claim a turn settles — a bounded dune RPC
probe (0.5 s worst case, immediate when no watch is registered) plus one full
workspace tree walk, on top of the two the claim's window boundaries already
cost.

## The test-suite cost model

The determinism contract behind this harness — how virtual time stays under the
test's control, and the invariants that keep the suite from hanging or flaking —
is `tui-testing.md`. This section is only its cost model.

A harness `Tui.run` boot in `test/tui` costs ~60 ms wall: ~2 ms boot,
~10 ms to the first frame, the rest launch-background settle and teardown. A
full turn against the in-process provider is ~215 ms with workspace tooling
off (the harness default; with tooling engaged the real `dune` spawns add
~1.5 s and a nondeterministic footer race — only tests that assert tooling
behavior should turn it on).

Consequences for test authoring:

- **Batch scenarios that share state into one boot** — the turn pilot prints
  three frames from one boot. Don't contort unrelated scenarios together.
- **Time is free.** `Tui.advance` marches virtual time in cadence-sized steps,
  firing due timers, and never sleeps on your behalf. Never trade determinism
  for speed by skipping settles.
- **The harness never sleeps on your behalf** beyond 1 ms scheduler breaths
  while real IO is genuinely in flight; if a test feels slow, profile it before
  touching the harness.
