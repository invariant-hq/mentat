# Architecture

Mentat is split into small libraries around a few narrow boundaries. Pure
libraries define checked values and state transitions; the executable composes
them with configuration and runtime capabilities; the CLI and TUI drive the
same protocol and render its facts.

This page describes relationships that span libraries. Individual types and
functions are documented in their `.mli` files.

## Layering

The principal layers are:

| Layer | Responsibility |
| --- | --- |
| Domain libraries | Pure values and transformations for paths, workspaces, LLM requests, permissions, sessions, protocol messages, diffs, reviews, and mutation facts. |
| Adapters | Interpret domain values at an external boundary: provider transports, Dune, OAuth, Git, the filesystem, and platform sandboxes. |
| Engine and executable | The engine drives turns through its ports; the executable resolves configuration, credentials, models, workspace posture, tools, persistence, and notices, and adapts resources to those ports. |
| Products | The CLI and TUI submit protocol commands and render committed facts, disposable progress, saved session projections, and diagnostics. |

Dependencies should point inward toward values. A pure library does not read
configuration or acquire a filesystem, process, clock, network, credential, or
store capability. An adapter receives the capabilities it needs explicitly.

A dune library is admitted only for a boundary invariant that no module can
enforce: a *firewall* — the archive provably does not link some dependency;
*containment* — C stubs or a heavy optional dependency a consumer must be
able to avoid linking; or *divergent reuse* — at least two real consumers
with different dependency footprints. A concept, an `.mli`, and a test suite
justify a module, not a library. A boundary whose invariant stops being real is
folded back to a module; a new boundary lands only through a change that names
the invariant it enforces. A dependency test pins the inward direction: no
upward imports, `Mentat_tool` free of session and engine, the agent's turn unit
and `Mentat_config` free of any effect library, and frontends free of everything
but the protocol and the value vocabularies its facts carry.

## Design rules

These constraints govern every library and are the review anchors:

- **Decide the guarantee, then derive the type.** A user-visible guarantee is
  settled in prose before a type encodes it; a type never stands in for an
  undecided product promise and lets the checker defer the decision.
- **One owner per durable fact.** A second module that stores, recomputes, or
  re-projects the same durable fact is a defect, not a convenience. Presentation
  fidelity follows from this: whatever a surface renders from durable facts must
  be derivable from durable facts, so the owning fact carries what rendering
  needs.
- **Speculative capability requires a named consumer.** A constructor, field,
  or lifecycle with no call site is deleted, not documented. Review anchors on
  the consumer survey, not on internal elegance.
- **Seams, not machinery.** A future capability is carried by an invariant the
  current code already maintains — stable identities, one waist, one-way
  dependencies — never by shipping the future's state machine early.

## One model turn

`Mentat_provider` contains static provider and model declarations. It annotates
provider-neutral identities from `Mentat_llm`; it does not read credentials,
configuration, or the network.

The executable resolves a configured model selector against those declarations,
resolves a credential separately, and asks the provider runtime to build a
`Mentat_llm.Client.t`. The client interprets a provider-neutral
`Mentat_llm.Request.t` through the provider's wire protocol.

The turn path is:

```text
static provider declarations + effective config
                    |
                    v
       executable model/account resolution
                    |
                    v
         provider-neutral LLM client
                    |
                    v
protocol command -> engine driver -> request/progress/response
                    |
                    v
       committed facts + disposable progress
```

Provider transports see the LLM identity and neutral request options, not the
whole provider catalog or the executable's configuration. Model-dependent
decisions belong at the narrowest layer that has the required facts: catalog
metadata is resolved by the executable, neutral request parameters travel in
`Mentat_llm.Request.Options`, and wire-only differences stay in the provider
transport. Unrelated decisions are not accumulated in a shared model-profile
object.

The provider-neutral client is callback-and-terminal, not a pull stream. A
provider owns and drains its wire stream inside `Client.run`, calls `on_event`
for ordered live progress, closes the transport on every exit path, and returns
one terminal `Response.t` or a structured error. Raw SSE and local decoder
streams do not cross the adapter boundary. HTTP-backed adapters share a private
`mentat_llm_http` bridge for Eio/Cohttp/TLS mechanics, bounded error responses,
Retry-After parsing, and SSE framing. Authentication, retry policy, and provider
error interpretation remain in each adapter.

The terminal response is authoritative. Live text, reasoning, tool-call, and
usage events can drive display or safe early work, but they are never appended
to the transcript. The interpreter reconciles them against the returned
response, whose assistant message becomes the durable session fact.

Before request preparation, the engine captures `Mentat_llm.Request.digest`, then
logs it immediately before the model call. The digest covers the model, full
model-visible message list, tools, and options, but excludes the prompt-cache
routing key. It is taken over content references rather than resolved bytes.
An attachment integration must therefore resolve `Content.Ref` values after
identity is captured and before the client runs. No current engine path creates
such references; every provider fails with `Invalid_request` if an unresolved
one reaches its boundary.

## Protocol, session, engine, and store

`Mentat_protocol` is the pure client waist: one typed `Command.t` vocabulary,
one pulled feed carrying committed facts and disposable progress, and read-only
queries. There is no `Outcome`, no `Pending`, and no separate live/replay
projection: an intent whose completion is a durable fact reports that completion
as a committed fact on the feed, and catch-up delivers the same values as live.

`Mentat_session` owns the journal and its pure replay state — the sole durable
truth of a conversation, detailed in the next section. It owns no model client,
scheduler, tool runtime, or store.

`Mentat_store` is the one library that touches durable bytes on the engine's
behalf. Over a single opened root capability it holds independent views: session
documents under whole-document optimistic CAS, the mutation ledger and its
content-addressed blobs, review records, the run fence, and the export bridge.
It keeps no clock and authors no metadata — semantic metadata is written by each
owning library before the byte-opaque save boundary — and its session view treats
session bytes as opaque, leaving session semantics in `Mentat_session`.

The engine is `Mentat_agent`: a private effect-free step unit decides each
transition as data — request the model, run a catalog entry, await a decision,
wait on children, or settle — and one interpreter commits that transition before
its single claimed effect runs. There is no assembly chain and no boundary
re-projection. The interpreter obeys one ordering law: persist the
provider-request claim before issuing the provider call; accept and persist
provider output before running its calls; persist a tool claim before its
callback; persist authority before the operation it authorizes; and make
mutation facts and blobs durable before the session settlement that references
them — the settlement is the commit point. The engine reaches the world only
through its ports; the executable adapts the store, provider runtime, and
workspace runtime to those ports, so the engine links no resource library. The
model and credential are turn facts, re-resolved at each turn boundary so a login
or model switch takes effect without rebuilding anything. The staged,
fail-closed startup and the cross-cutting policies the executable owns are
described under the composition root below.

## The session journal

The journal is the sole durable session truth. Every fact whose lifecycle is
scoped to a conversation lives there, in one order: turn boundaries, accepted
model responses, provider-request claims, tool claims and settlements,
decisions, plan and task facts, compaction, delegation edges, and queue
changes. The admission test is strict — a fact is journaled only if it changes
replayed product state or is required to recover an effect. There are no sidecar
stores for plans, todos, or subagent runs; branch, rewind, export, and
replay follow the one sequence. Value vocabularies the journal carries
(permission, diff, LLM content, tool values) are stored through their owning
libraries' codecs; the journal does not redefine them. The mutation ledger and
blob store are separate durable domains with a different lifecycle and size,
correlated to sessions, turns, and claims by the id vocabulary the session owns.

Permission review, user questions, plan approval, and a child agent's question
to its parent are one durable concept — a **Decision**: requested, pending,
resolved, with a closed typed kind carrying its own presentation and answer
codec. The state machine is generic; the meaning never is. The first valid
answer wins and a later answer is refused as already resolved; the resolution
records the principal that answered, so decision authority is auditable. A
recorded tool claim carries its id, name, canonical input, and permission
requests; its settlement is a prepared payload, a returned result, or
`Ambiguous` — there is no contract, terminal envelope, impact field, or retry
outcome. Branch and rewind cut only at validated quiescent points — no running
effect, no unresolved decision — and a branch is self-contained, inheriting no
executable intent or pending decision.

## Effect guarantee and ambiguity

Every externally effectful operation — a tool callback, a provider call, a
revert — follows one forward protocol: **persist the claim, run the effect
once, persist the result.** A crash between claim and result settles the
operation as `Ambiguous`: a durable fact stating the effect may have run and no
result was recorded. Mentat never silently retries an unresolved effect and never
reconstructs an unrecorded success; retrying is a new operation with a new
identity, chosen by the model or the user, not by recovery machinery. There is
no recovery-kind taxonomy, operation-key table, or reconciler callback anywhere
in the system. Under the run fence the provider call obeys the same rule: a
claimed request with no recorded response settles `Ambiguous` and is never
re-issued.

An operation may declare a stable external idempotency marker; after ambiguity
it reconciles by observing the external system's authoritative state, never by
fabricating a success. No current operation declares one — the clause exists so
provider idempotency keys and a future connector reconcile rather than
duplicate, without amending this rule.

Ambiguity is user-visible by design: surfaces render an ambiguous settlement
distinctly — not as failure, not as success — and the transcript carries the
synthetic result so the model can decide what to verify. Live progress — model
deltas, tool pulses, spinner state — is a distinct type from durable facts: it
is never persisted, never replayed, and dropping or coalescing it changes no
durable projection. The committed fact carries the same identifiers and
supersedes its pulses.

## One driver per session

At most one process drives a session at a time. The interpreter acquires the
session's run fence before its first effect — including the provider call — and
holds it until the turn settles; an attached interactive handle may hold it
across turns. A second driver receives a structured `Busy` naming the owner;
whether to wait is caller policy, never automatic. The fence is an OS advisory
lock, so owner death releases it and a new driver re-reads the journal head
before executing. Release proves the driver is gone, never that its effects are
— which is exactly what an open claim's `Ambiguous` settlement states. The
fence's cross-process and same-process mechanics live in `lib/store/run_lock.mli`.

Reading a session is not driving it. A read-only feed on a session another
process drives is served through the store's fence-free view: it delivers
committed facts without acquiring the run fence and never contends with the
driver. This is what lets a threads panel watch a running child.

## Frontend parity

Every surface — the TUI, headless CLI, and any future client — drives the same
client waist: one typed command vocabulary plus one feed, owning only drafts,
selection, and rendering. Parity is structural because the vocabulary and the
feed are shared, not because every operation shares one lifecycle: intents whose
completion is a committed session fact travel as commands, while account,
settings, review, session-lifecycle, and manual-compaction operations are typed
request/completion flows on the same client. Frontends depend on
`Mentat_protocol` plus the pure value vocabularies its facts carry; they never
depend on the engine, the store, provider transports, configuration internals,
or session replay. No frontend classifies calls, walks transcripts for final
text, owns continuation or waiting policy, or persists product state — deleting
one frontend leaves the other fully functional.

What is deliberately *not* the client has four permanent homes, and naming them
is the boundary. **The engine when idle** owns continuation and completion
detection — the client asks for the next admission and never decides one. **The composition root** adapts the store, workspace runtime, and provider
runtime to the engine's ports; the client links none of them. **The offline
executable** performs sessionless configuration and CLI edits with no engine.
**The frontend itself** owns only local draft, scrollback, and opening a URL.
The client is the seam between these; it absorbs none of their responsibilities.

The protocol waist carries domain values through their owning libraries' codecs
and mints no mirror or placeholder of its own. This gates the query surface: a
query whose owner codec does not yet exist is deferred — unrepresentable until
that codec lands — rather than stubbed with a protocol-local shape. Session
listing and view codecs are owned by the session library (the store stays
byte-opaque; the protocol does not accidentally mirror them), and the
values-with-origins codec is owned by configuration, where redaction is by
construction. Optional refinements such as search are data on an existing
listing query, not new constructors.

Commands carry no principal: v1 has one command source, the process-local client
bridge, so admission authority is structural. The principal appears in exactly
one place — a decision resolution's recorded answerer — with two inhabitants,
`Local_user` and `Unattended_policy`; an unattended principal may only deny, and
resolution rejects any other answer from it. Command submission returns a plain
result, because acceptance is durable admission rather than completion and no
resumable position token exists at admission.

## The composition root

The executable is the sole composition root. It resolves configuration and
trust, constructs providers, builds the tool catalog, adapts the store, provider
runtime, and workspace runtime to the engine's ports, and hands each frontend a
`Client.t`. There is no service locator and no public host library; setup logic
that no library owns is executable-private. That the full client assembles only
here is forced, not chosen: the engine links no provider runtime, configuration
IO, or review store, so it cannot build the account, settings,
session-lifecycle, or review cones itself. It supplies the session cone over the
running engine; the composition root wraps that with its own responders for the
rest and produces the single `Client.t` a frontend holds. Startup is staged and
fail-closed —
directories, then configuration, then immutable trust, then the sealed sandbox
combined with the permission posture, then credentials, sessions, and producers
— so a restricted posture is never weakened by a later stage.

Configuration splits along a purity firewall. `Mentat_config` owns the pure core
— the typed field vocabulary, layered precedence with origins, the parser, and
structure-preserving edit planning — and cannot touch disk. File discovery,
byte-capped reads, atomic writes, parent-directory creation, `.gitignore`
maintenance, cross-process locks, and trust IO and prompting are
executable-private; credential-store IO is owned by the provider runtime.
Frontends query configuration rather than reading it.

A settings change through the client — model, reasoning effort, permission-review
mode, sandbox mode — is an ephemeral executable-state *overlay* keyed by session
id. It reaches the engine through the engine's already-session-keyed per-turn
configuration callback, so it needs no engine change and takes effect at the next
turn boundary while an active turn stays frozen. Its lifecycle follows the
session: fork and rewind copy the source session's overlays, archive and restore
preserve them, create and delete clear the target's, and a new process starts
from resolved configuration with no overlays; a failed validation or lifecycle
operation mutates no overlay. Reasoning effort resolves explicit-first,
model-default-second: an explicit overlay effort drives both the model's
requirements and the request options, while absent effort takes the resolved
model's default reasoning — never the shared configured effort. The same
resolution governs a configured model selection.

The composition root owns four cross-cutting policies over its own commands:
validate semantic input at the argument boundary before any smart constructor;
sanitize output — emit no escape sequences of its own, disable third-party
styling at startup, strip control characters from untrusted model text
unconditionally, and wrap every JSON output in one versioned envelope; render
every library error through one exit-code ladder with no raw exception reprs and
no conflation of absent with malformed; and guard the process so no command
exits with an internal-error backtrace on stderr for any user- or
environment-supplied input. The exit codes and the JSONL event stream are a
product contract, documented in [`manual/headless.md`](manual/headless.md).

A store-touching operation is reached two ways. When a `Client.t` exists it is
served by that client's cone over the running engine; when no engine runs the
executable — which legitimately holds the store — performs the same computation
directly against the store. Read-only and metadata-only operations are these
offline twins; an operation that mints a new journal is client-routed; a twin
and its online cone bottom out in the same library functions and cannot diverge.
Because the composition root is the only place shared frontend vocabulary may
live, each frontend re-creates its own small output, exit, and directory helpers
rather than linking a frontend-support library.

## Executable tools

`Mentat_tool` defines a runtime-independent executable tool as a typed input
decoder, permission planner, handler, and typed-output encoder. Dispatch has two
steps: decode once, then inspect permission requests before running that same
decoded call. Permission planning and execution therefore cannot disagree
about the input.

`Mentat_tools` contains the concrete file, search, edit, shell, web, and OCaml
tools. A tool's output is model-visible text plus optional compact summary
JSON, never evidence a fact owner may trust: a mutating tool applies its
change through the workspace-io capability and discards the returned edit
result, and the engine records the mutation from the capability's claim scope,
keyed by the tool claim id, without inspecting tool output. The typed summary
JSON drives trustworthy status rendering without parsing model-visible text,
but is never mutation evidence.

The executable builds a catalog from the resolved workspace, sandbox, model, and
skills. A read-only sandbox omits native mutating and code-executing tools from
the catalog. The shell tool remains present because its command is interpreted
through the sealed command sandbox.

Questions, plans, todos, and subagents are engine verbs in that one catalog
rather than `Mentat_tool` executables — one dispatch surface, not a
second routing system. Their state belongs to the session workflow, not to the
workspace-tool catalog.

## Paths and filesystem authority

The path stack separates syntax, addressing, and observation:

```text
Lpath                normalized portable lexical syntax
     |
Mentat_workspace     pure addresses under admitted workspace roots
     |
Mentat_workspace_io  filesystem/process effect boundary and mutation guards
```

`Lpath` is deliberately a standalone, stdlib-only dependency root. The
sandbox and other path-only consumers need canonical equality and
component-aligned containment without acquiring workspace addressing or
filesystem authority; permission composes the same lexical vocabulary with
workspace-root identity. The `Rel`/`Abs` split and normalization contract
therefore belong to the path library, while their exact public contracts live
in `otherlibs/lpath/lpath.mli`.

`Lpath` does not know whether a path exists or belongs to a workspace.
`Mentat_workspace` resolves input into typed workspace addresses without reading
the filesystem. `Mentat_workspace_io` is the effect boundary: it checks
realpath containment when dereferencing addresses, refuses symlink escapes, and
protects top-level `.git` and `.mentat` metadata from native mutation tools.

The command sandbox independently protects the same metadata names inside its
writable roots. Sharing the names makes the native edit path and the shell path
enforce the same authority boundary, while their implementations remain
separate.

`Mentat_workspace_io` is also the single sealed process-spawn boundary: every
command execution — the shell tool, notice producers, Git, and TUI helpers —
passes through it with its sandbox lowering applied. Its cleanup contract is
leader-only: it terminates the process it spawned, never a process group, so
descendants of a cancelled or timed-out command may outlive it. Recovery
therefore treats an open claim's effects as possibly still running — exactly
what its `Ambiguous` settlement states.

## Digests and content references

`Mentat_digest` is the neutral SHA-256 boundary shared by otherwise independent
libraries. Its bare digest type represents only the hash of exact bytes;
semantic roles such as sandbox profiles remain the responsibility of their
consumers. `Mentat_digest.Content_ref` is the one structural refinement: it
pairs a digest with a byte length for content addressing, integrity checks, and
optimistic concurrency. Its canonical `sha256:<hex>:<length>` token is the
durable text and JSON form.

`Mentat_llm.Request.digest` is a domain-owned canonical projection built on the
bare digest. Its versioned bytes and exact inclusion rules live in the LLM
library, not in `Mentat_digest`; this keeps request identity stable without
teaching the neutral hashing layer about models, messages, tools, or options.

The digest implementation does not canonicalize input or authenticate values.
Callers define canonical bytes for their own domains, and use the
length-framed, domain-separated `Mentat_digest.key` operation when deriving
truncated identifiers from several fields. Incremental hashing remains outside
the public surface until a streaming consumer requires it.

## Permission, sandbox, and trust

These are three different controls:

- `Mentat_permission` decides whether a trusted description of an operation is
  allowed, denied, or requires review. It is pure policy and grants no runtime
  capability.
- `Mentat_sandbox` confines command-bearing tool and integration processes and
  records enforcement evidence. It does not decide whether an operation should
  be attempted or whether project customization should activate.
- Workspace **trust**, resolved by the executable, decides whether ambient
  project configuration, instructions, skills, notices, and built-in tooling may
  activate. It grants no tool permission and does not weaken sandbox
  confinement.

Native workspace operations are fixed product allowances because their typed
implementations enforce the workspace boundary. Ordinary command execution is
credited only when its permission fact proves project reads and restricted
networking through the sealed sandbox, or records an explicitly selected
external boundary. Read-all, network-enabled, direct, and escalated routes do
not receive that credit. A narrow high-impact review rule precedes command
credit as an accident interlock.

Trust resolves once while configuration loads. Every ambient consumer reads
that immutable value, so an unknown or explicitly untrusted workspace can
still use ordinary file and model tools while project-owned inputs remain
unopened and automatic project processes remain stopped. Interactive startup
may persist a decision and reload once before constructing the normal app;
headless startup never infers trust.

The complete user-visible behavior is documented in
[`manual/security.md`](manual/security.md).

## Durable mutations and review

Session events describe the model/tool conversation. Workspace mutation facts
are a separate durable log in `Mentat_mutation`: checkpoints, file changes, and
reverts are correlated with sessions, turns, and tool claims but are not added
to `Mentat_session.Event`.

Concrete mutating tools apply edits through the workspace-io capability, which
returns the authoritative edit result to the engine's open claim scope; the
tool retains none of it. The engine lowers that claim-scoped result to
content-addressed mutation facts, keyed by the tool claim id, and stores file
bytes in `Mentat_store`'s per-session, write-once blob store. Session diff and
revert commands consume this engine-owned record; edit diffs and the revert
affordance come from these mutation facts, never from tool output. Because the
session document and the mutation ledger are separate stores, their consistency
is an ordering law rather than a transaction: mutation facts and blobs are made
durable before the settlement that references them, so an orphan fact no settled
claim references is ignored by replay and reclaimable, and a settled claim never
references a missing fact. There is no blob garbage collection: blobs live for
their session's lifetime and are reclaimed only by session deletion, and any
future retention policy must preserve revert-reachability.

Before the first tool callback of a turn the engine attempts one conservative
checkpoint, regardless of the tool's declared permissions. If checkpointing is
unavailable or degraded, execution may continue but the product states "revert
unavailable" durably: no surface claims revertability the evidence cannot
support. Revertability has exactly one owner, `Mentat_mutation`, derived from
validated evidence; revert itself validates every target, revalidates before
each write, and reports per-path confirmed, failed, or ambiguous outcomes rather
than claiming success it cannot prove.

The shipped revert is an offline CLI flow over the snapshot store. A richer
revert-under-fence design is anticipated but *deliberately unbuilt in v1*, named
here so it is not mistaken for current behavior: a store revert-append carved
out of the mutation-append path; the demotion of any checkpoint recorded before
a possibly-mutating recovery point, so a revert to a demoted checkpoint is
offered only behind an explicit user confirmation that names the condition; and
a path-divergence check at settle time that downgrades such confirmations to
`Ambiguous` when the workspace no longer matches. When it lands it strengthens
this section's honesty guarantees under the run fence; until then, revert is the
offline snapshot flow above.

`Mentat_review` is another pure state machine. It describes a feature snapshot,
review marks, CR occurrences, cursor, and verdict. The Git worktree effects that
load a review snapshot live in `Mentat_workspace_io`, the filesystem/process
effect twin, alongside every other spawned command; the TUI renders and drives
the pure review state. Conservative refresh rules discard review state when
content identity cannot prove that it is still valid.

## Error boundaries

Programmer-local invalid construction raises `Invalid_argument`. Runtime
boundaries return structured errors. Durable workflow conditions are recorded
as session/protocol facts rather than flattened into terminal diagnostics.

Lower-layer errors lower to protocol arms at the engine bridge and the
composition-root responders — never in the client, which only forwards. Each
mapping is fixed: an engine `Busy { owner }` gains the session id to become
`Busy { session; owner }`; an engine decision mismatch becomes
`Decision_not_pending` or `Already_resolved` once the kind and id are checked;
a store `Not_found` becomes `Session_not_found`, `Archived`, or `Deleted`; and
every store, configuration, credential, or review IO failure becomes
`Unavailable` carrying a diagnostic. The protocol arm set is closed at that
boundary; no raw lower error reaches a frontend.

The protocol error surface omits by design what v1 cannot mean. There is no
cursor-expiry error — v1 retains the whole journal, so a feed suffix is always
available. There is no not-permitted arm, because admission authority is
structural. There is no free-string invalid-input arm — a malformed command is
unrepresentable and caught locally before submission. Provider failure is a
settled turn fact, not an error arm, and there is no revision-conflict arm
because a frontend holds no revision. The `Admission_unknown` shape is reserved
but never minted in v1; it lands only with a daemon transport that owns
idempotent admission.

The project-wide classification and propagation rules are documented in
[`dev/error-model.md`](dev/error-model.md), including fatal exception handling
and background-fault containment.

## Seams

Several future directions are anticipated. Each is carried only by invariants
the current build already maintains; the invariant is the whole present cost,
and none of these features is built now. A change that breaks one of these
invariants forecloses its future direction silently, so they are load-bearing.

- **Daemon and remote clients.** The client waist is transport-neutral and fully
  serializable; committed facts replay identically and the feed catch-up is
  gap-free; positions are session-scoped and membership-validated; session and
  workspace ids encode no host, pid, path, or frontend; durable paths are
  workspace-relative; no frontend owns continuation. Sockets, request-id
  envelopes, idempotent admission, and inbox/outbox persistence are not built.
- **Project work and swarms.** Subagents are child sessions with immutable
  delegation edges carrying a parent-minted child id and a base revision; the
  engine assumes it is not the only root (capacity is injected policy, and the
  store's per-session locks already serve many roots); writable isolation and
  explicit handoff are the only write path for children; the task board is
  session-scoped and never a scheduler. A future project layer depends on the
  engine, never the reverse. A threads view over children is a read view, not a
  new record: the parent journal holds no per-child status, a child's result
  reaches the parent only as its parked `wait` call's tool result, and there is
  no merged cross-session order — positions are per-session and interleave by
  arrival, each child watched through the fence-free read view.
- **Automations and connectors.** External-service effects are not workspace
  mutations and never enter the mutation ledger; review publication is separate
  from review state; the effect guarantee's reconciliation-oracle clause gives
  connector effects their semantics without amending it; tool identity and
  decision authority cannot be widened by external text.
- **Authorization plane.** Every command source and every decision resolution
  records its principal, so when a second real human or device principal
  arrives the who/route axes re-split additively instead of breaking the
  resolution fact. Permission, sandbox, and trust stay untangled from client
  authorization by construction.
- **Extensions and MCP.** The catalog is the only dispatch path; a dynamic tool
  is an ordinary `Mentat_tool.t` whose provenance then joins its identity; context
  sources stay concrete modules rather than a hook bus.

## Deliberate exclusions

The following are rejected on purpose; re-introducing one silently reverses a
decision:

- **A tool recovery algebra** — contracts, terminal evidence, impact GADTs,
  recovery kinds, operation keys, reconcilers. The effect guarantee replaces it
  with a rule a user can understand and a test can falsify.
- **A per-tool write flag or impact type.** Write authority has one meaning that
  `Mentat_permission` answers from an operation's requests; tool authors declare
  requests, not impact promises.
- **Re-running staged preparation on resume.** Preparation may observe the
  workspace, and re-observation would silently substitute a different plan under
  an old approval — the exact failure the permission flow exists to prevent.
- **A generic hook bus or plugin kernel.** Closed typed seams — catalog entries,
  context modules, decision kinds — compose in OCaml without sacrificing
  exhaustiveness.
- **Frontend-owned drive loops.** Continuation and waiting classification
  belong to the engine, never to a surface that "just needs one small loop".
- **A public effect language.** The turn unit returns its boundary as data
  interpreted by exactly one component, the engine's interpreter; nothing
  outside the engine links the planner.
- **Event-sourced storage now.** Per-session documents with content addressing
  and validated replay already give atomic session commits, corruption
  isolation, and complete export.

## Validation

The architecture is meant to be falsified, not argued. The invariants above are
pinned by black-box traces, crash-injection at claim/effect/commit boundaries,
and a dependency test, so a regression fails a check rather than review. The
load-bearing properties:

- Full replay equals snapshot-plus-suffix replay; invalid orderings fail with
  located structured errors.
- No effect starts before its claim commits — including the provider call;
  crash injection at any boundary yields exactly one settled or `Ambiguous`
  outcome, never a silent retry and never two terminals.
- A second driver of one session receives `Busy`, at most one provider call is
  issued, and owner death releases the fence for a successor that re-reads the
  journal head.
- A tool callback consumes exactly the decoded value its permissions described;
  declaration or request drift blocks resume structurally; the permission
  process-exit journey round-trips through the prepared value with every
  equality check exercised, and resume never re-runs preparation.
- A denied call runs nothing and appends one paired result; an interrupted turn
  settles every dangling claim; a sibling that never started is `Interrupted`,
  not `Ambiguous`; a late result for a settled claim is discarded; crash
  recovery settles unsettled claims `Ambiguous` even when an interrupt was
  recorded.
- Committed facts are byte-identical live and replayed; dropping every progress
  pulse changes no durable projection; a feed suffix is gap-free.
- Every protocol command, query, fact, and request-flow value round-trips
  through its codec, with no function-typed or in-process-only payload; session
  and workspace ids are stable across process, host, and working directory.
- The dependency test passes: no upward imports; `Mentat_tool` free of session
  and engine; the turn unit and `Mentat_config` free of any effect library;
  frontends free of everything but the protocol and its fact vocabularies.
