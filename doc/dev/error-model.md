# Error model

Mentat classifies failures by who can act on them and whether they belong to the
durable workflow. Keep errors structured until the product boundary that can
render useful recovery guidance. The relationships this page describes span
libraries; the boundary-level summary lives in
[`../architecture.md`](../architecture.md) under "Error boundaries".

## The three classes

### Programmer errors

Programmer errors are invalid construction from trusted code or states that
should be impossible after validation. Examples include an empty static
provider id, duplicate declarations in a statically assembled catalog, or an
invalid argument passed to a smart constructor by executable code.

These failures raise `Invalid_argument` or expose an internal-error branch at a
boundary that cannot raise. They are not ordinary recovery paths. Fix the
caller or the violated invariant; do not catch the exception to continue.

Input that came from a user, file, environment variable, provider, or store is
not programmer-local merely because it eventually reaches the same
constructor. Decode and validate it at the boundary, returning a structured
error instead.

### Recoverable boundary errors

Boundary errors describe runtime input or state that a caller can repair:

- invalid CLI or configuration input;
- unreadable or malformed config and credential stores;
- unknown providers, models, or reasoning choices;
- missing or blocked credentials;
- unresolved workspaces;
- unavailable required sandbox enforcement;
- storage conflicts and corrupt documents.

Return `(value, error) result` for these conditions. Error variants are the
matching surface for control flow; `message`, `pp`, and diagnostic values are
for people. Tests should match structure below the product boundary and exact
rendering only in black-box product tests.

At the client waist, boundary errors are one flat, closed type,
`Mentat_protocol.Error.t`: `Busy`, `Session_not_found`, `Archived`, `Deleted`,
the decision and goal mismatches, `Invalid_title`/`Invalid_api_key`, and one
opaque `Unavailable` carrying a `Mentat_diagnostic.t`. No arm wraps a lower
library's error chain; a caller chooses a recovery from the flat arm set, never
by unwrapping implementation layers such as `Run (Session (Store error))`.
Inner structured detail that helps a person survives inside the diagnostic
payload, but the recovery decision is made on the arm.

Hints are produced where candidate knowledge lives. Model lookup knows the
valid model ids; config parsing knows the supported keys; the outer CLI should
render those hints rather than recreate them.

### Durable workflow facts

Some adverse outcomes are part of the session rather than command-boundary
errors:

- a permission request or denial;
- a tool call that failed, was interrupted, or settled `Ambiguous`;
- a turn that is waiting, failed, or was cancelled;
- a compaction or subagent lifecycle transition.

Represent these as typed session or protocol facts with stable codecs and
replay semantics. The engine consumes them, the store persists them, and the
CLI or TUI renders them. Do not throw them away by converting them prematurely
to an exception or a terminal diagnostic string.

The same subsystem can produce different classes at different boundaries. For
example, failing to construct a provider client is a recoverable
composition-root error before a turn starts; a provider call failure during
execution is a settled turn fact — `Mentat_protocol.Fact.Turn_provider_failed`
followed by the generic turn settlement — not a protocol error arm; and a
provider response successfully accepted into the session becomes durable turn
data.

## Propagation rules

Follow these rules when adding a failure path:

1. Validate untrusted input at the boundary where its source is known.
2. Return a structured error if the current caller can recover or report a
   specific action.
3. Record a durable fact if the outcome changes session state or must survive
   replay.
4. Lower errors to protocol arms by recovery path, not source-module ancestry,
   and only at the two lowering boundaries below.
5. Render once at the product boundary. Do not parse rendered text for control
   flow.
6. Preserve cancellation as cancellation. Do not turn it into a generic
   failure or swallow it in a catch-all handler.

Lower-layer errors lower to `Mentat_protocol.Error.t` arms at exactly two
places, never in the client, which only forwards. The engine bridge maps engine
conditions — `Busy { owner }` gains its session id to become
`Busy { session; owner }`, a decision mismatch becomes `Decision_not_pending`
or `Already_resolved`. The composition-root responders map a store `Not_found`
to `Session_not_found`, `Archived`, or `Deleted`, and every store,
configuration, credential, or review IO failure to `Unavailable` carrying a
diagnostic. The arm set is closed at that boundary; no raw lower error reaches
a frontend.

## Diagnostics

`Mentat_diagnostic.t` is the common rendering form for user-fixable boundary
errors. It carries a single-line primary message, optional multi-line context,
and actionable hints. An error-owning library exposes
`Error.diagnostic : t -> Mentat_diagnostic.t` where the fixable knowledge
lives; a product renders every such error uniformly at one boundary with
`Mentat_diagnostic.to_string`. Diagnostics are presentation values — build and
render them; do not inspect or parse them for control flow.

Diagnostic text is not stable program input. Stable automation uses exit
codes, JSON/JSONL fields, error variants, and durable session facts.

## Fault containment

Fault containment is the fallback for failures that escaped the expected error
transport above. It does not turn exceptions into a second recoverable-error
API. Fix faults at their source and keep containment at the few effect
boundaries that can preserve a valid session.

Backtrace recording is application policy, not library policy. `bin/mentat/main.ml`
enables it once at process entry so both headless commands and the TUI carry a
diagnosable trace. Libraries must not mutate this process-global runtime knob.

### Fatal path

`bin/mentat/main.ml` records backtraces, installs the diagnostics reporter, and runs
cmdliner with `~catch:false` so no exception is swallowed by cmdliner's own
exit-125-with-backtrace handler. An exception that escapes a responder reaches
one guard, which classifies it with `Exit_status.of_exn` and renders it through
the single exit-code ladder — never a raw exception repr on stderr. An
internal-invariant exception is the one case that writes its backtrace to a
crash report under the state home (`Log_setup.write_crash_report`); stderr sees
only a clean one-liner that names the saved report. Every other classification
emits its diagnostic through the ladder and exits with the mapped code.

While the TUI runs, Matrix (mosaic) owns terminal restore: it returns the
terminal to a sane state before any exception propagates out of the Mosaic loop
to the guard above, so a crash never leaves a wedged terminal. Uncatchable
failures such as `SIGKILL` and operating-system OOM termination remain outside
Mentat's error model.

Do not add a second crash-file format, signal stack, or exit-code scheme around
this path. Correct the boundary that lost or hid the original exception
information.

### Non-fatal seams

An exception from one background activity must not tear down an otherwise valid
session. Current containment boundaries are:

| Boundary | Fault behavior |
| --- | --- |
| Client cone (`Mentat_client.Driver`) | Re-raises cancellation; maps another exception from a result-bearing field to an operation-labelled `Mentat_protocol.Error.Unavailable`, without exposing exception text. |
| Session feed (`Mentat_client.Feed`) | Surfaces closure and catch-up position errors as structured `Closed`/error values through `next`; a closed feed is a local delivery outcome, never a background exception or a wire value. |
| TUI runtime (`Mentat_tui.Runtime`) | Folds client and capability failures into the application as structured messages and does not terminate the Mosaic loop; runtime-owned feed and login cleanup is cancellation-protected and exception-contained. |
| Workspace watcher and notice producers | Publish a warning or degrade that producer; the run continues. |
| Session and mutation store | Return structured corruption and IO errors; invalid persisted data does not escape as a background exception. |

When adding background work, route failure into one of these seams — or an
equivalent explicit degradation — rather than letting an exception escape a
fiber into a shared switch. Preserve cancellation as cancellation at every seam.

### Turn settlement

A turn that becomes durably active must reach a terminal `Turn_finished` event;
an error that merely propagates would leave the turn active in the saved
session, and an active turn is not inert — the session refuses a new turn, fork,
rewind, archive, and delete against it with `Error.Active_turn`, so every later
command would be refused. Turn terminality is therefore an engine guarantee,
owned by
the one component that drives turns, `Mentat_agent`'s interpreter, not a
frontend concern. Two distinctions the interpreter must preserve:

- **A cancellation is not a failure.** It surfaces as an ordinary provider
  error *value*, `Mentat_llm.Error.Cancelled`, not an exception — the client
  polls the cancel flag mid-stream. A durable `Interrupt_requested` event then
  settles the turn with an `Interrupted` outcome; a claim that never started is
  `Interrupted`, not `Ambiguous`. Closing such a turn as failed would both
  mislabel the outcome and strand the interrupt.
- **A crash between claim and result is `Ambiguous`, not failed.** The effect
  guarantee — persist the claim, run the effect once, persist the result —
  settles an unrecorded provider or tool effect as a durable `Ambiguous` fact,
  the honest statement that the effect may have run. The interpreter never
  silently retries it and never fabricates a success.

These are the durable-fact expression of the two rules above: cancellation
stays cancellation, and an ambiguous effect stays ambiguous, all the way into
replayed session state.
