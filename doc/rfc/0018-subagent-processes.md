# RFC 0018: Subagents as OS processes — the killable child

- Status: Draft (synthesis of three blind designs — minimal-mechanism,
  supervision/failure-semantics, warm-pool/daemon/product — seeded by the
  2026-07 OTP exemplar study, grounded by a full-knowledge verification
  scout at HEAD `7cc7ffac`, and hardened by three adversarial reviews
  (simplicity, correctness/concurrency, rent) whose accepted findings are
  folded throughout; 2026-07-26 design campaign, maintainer-directed)
- Audience: Mentat maintainers; the turn+agent (RFC 0011), server
  (RFC 0017), store (RFC 0010), and architecture (RFC 0000) authors
- Derives from: RFC 0011 (§8 sibling drivers + the semantic delegation
  graph, scheduler stateless-about-status, content-derived child ids; §11
  honesty laws — "process death is the escalation", leader-only cleanup;
  §7 the durable-first interrupt), RFC 0017 (the daemon, instance registry,
  `serve`/`connect`, all-broadcast decisions; §8 crash honesty), RFC 0000
  (D1 honest ambiguity, D13 settle-then-idle, D16 the journal is the sole
  durable truth, D17 one driver per session with owner-death release,
  Method rule 2 no persisted derived state), `lib/store/run_lock.mli`,
  `otherlibs/subprocess`, and the code seams cited inline
- Compatibility: additive. The in-process delegation path is byte-unchanged
  and remains the single-process CLI default through the process backend's
  landing. Process children are a composition-root backend choice behind
  one injected seam; a golden spawn→wait→integrate journey must be
  identical across backends after normalization of timing-dependent fields
  (§10). (Amended by RFC 0024: "forever" was a compatibility promise, not
  a derived design — once the brokered backend has landed and the golden
  has proven it identical in real use, the in-process arm must re-justify
  its existence against its true rents — deterministic unit-tier
  delegation tests, and the one-shot CLI's unrepresentable-orphan teardown
  — or be deleted, collapsing delegation to a single materialization
  story. RFC 0024 §13 carries the trigger.)

## Summary

This RFC pins the design that makes a delegated child a real OS process:
**the killable child**. Its honest justification has three legs, stated in
order of force:

1. **The remote-subagent consumer.** A child on another machine is the
   milestone trigger the maintainer named; a remote child *is* a process,
   so the local process seam is the remote story's prerequisite, and
   location transparency — every fact journal-derivable, no shared-heap
   coupling — is what makes local and remote the same design.
2. **Isolation.** A process child gets a fresh heap (crash isolation for
   free), OS resource limits, and — the boundary's second genuine win —
   kernel-enforced sandbox tightening: a read-only child confined by
   Seatbelt/bwrap, not merely by catalog discipline. It also retires the
   documented limitation that parallel generic children share one
   workspace un-isolated (`bin/composition.ml:2274-2275`).
3. **Preemption, as defense-in-depth for a hazard class.** A callback
   parked in `run_in_systhread` is uncancellable in-process (RFC
   0011:943-945; "process death is the escalation", :1202). Honesty
   requires saying what the adversarial review established: **no tool in
   today's catalog can park unbounded model-controlled work in a
   systhread** — all thirteen `run_in_systhread` sites are bounded
   infrastructure operations, model work runs in subprocesses that are
   already killable (`subprocess.mli:108-115`), and the one historical
   incident of this class (the fswatch teardown hang) was fixed at source
   with an external wake, not a process boundary. `kill(2)` on a child is
   the *class* defense — the guarantee that no future tool, native binding,
   or provider regression can ever wedge a delegation unkillably — not the
   cure for a bleeding wound.

The design is small because the hard part is already built and verified at
today's HEAD: content-derived, re-spawn-idempotent child ids
(`"sub-" ^ H(turn, call)`, `lib/agent/step/mentat_agent_step.ml:638-646`);
`child_result`, `rebuild_children`, and the `Await_children` park all
speaking journal, not fiber (`lib/agent/mentat_agent.ml:107-117,
506-541`); a per-session run fence that is an OS advisory lock with
owner-death release and `O_CLOEXEC`, already correct across processes
(`lib/store/run_lock.mli`, D17); all-broadcast durable decisions (RFC 0017
§5). After waves 4–11 the only non-journal-derivable driver state is
deliberately-ephemeral visibility. State was always outside the process;
this RFC moves the process without moving the state.

**The architecture in one sentence: a child process is `mentat.server`
serving exactly one session — its own — and the daemon is its `connect`
client.** The registry entry's `Driver.t` is socket-filled instead of
in-process, and `route_session` routes the parent's wait, the child's
feed, and any frontend's decision answer through code that already exists.
The genuinely new machinery is bounded: a **child broker** in the daemon
(spawn, admit, observe, reap, escalate), an **injected materialization
seam** where `observe_delegation` today forks a sibling fiber, the
**session-keyed child registration** beside the workspace-keyed registry,
and — separately gated — a **warm pool** that amortizes the per-child boot
tax *when a measured spawn rate earns it* (§6).

Three scout corrections frame the scope honestly: RFC 0017 defines no warm
pool anywhere (its registry lazy-boots and eagerly evicts — the pool is
new machinery defined here); the registry is workspace-root-keyed, so
child processes need session-scoped registration; and today's settlement
wake is an in-process heap call that must become an observed-and-re-derived
event across the boundary (§7).

## 1. Laws

- **L1 — Location transparency of facts.** Every fact a child produces is
  journal-derivable; the parent is a function of the child's journal head,
  never of its runtime representation. *Historical referent:* the
  nested-switch bug RFC 0011 §8 fixed. *(Data-flow law; its code-structure
  counterpart is L9.)*
- **L2 — No shared-heap coupling.** No live closure, promise, switch, or
  mutable cell crosses a delegation edge. Cross-boundary channels are
  exactly: the child journal, the parent journal, the run fence, and the
  protocol wire.
- **L3 — Links are semantic, separate from the runtime graph.**
  `cancel_tree` walks the delegation graph read from journals; it never
  kills an OS subtree as a *delegation* cancel. The OS process tree is
  used only for a child's own tool descendants (§5).
- **L4 — Idempotent re-spawn via content-derived ids.** Re-spawn
  re-derives the identical child id from the parent journal; a still-live
  child's held fence means *bind as observer*, never a duplicate and never
  a spawn failure (§7.4).
- **L5 — The journal head is the sole outcome truth; the exit code and
  signal are liveness only.** They are orthogonal: exit 0 does not prove
  settlement, a signal does not prove failure; death triggers a head read
  and the child's own total `recover`, nothing more. Corollary (the
  vocabulary guard): no `Killed`/`Crashed`/`OOM`/`Signalled` settlement
  kinds — every OS failure maps onto the existing
  `Faulted`/`Interrupted`/`Ambiguous` vocabulary.
- **L6 — At-most-once across the boundary; the boundary never manufactures
  a retry (D1).** A child dead mid-claim leaves an open claim the child's
  own `recover` settles Ambiguous; re-spawn resumes the same child from
  its journal and never re-runs settled turns.
- **L7 — Capacity is journal-rebuildable and unpersisted.** Admission
  counters are memory-only, rebuilt from live-edge journals on restart
  (the `force_reserve` discipline), and symmetrically decremented on every
  reap. Persisting a permit — or holding one in shared memory — is a
  finding.
- **L8 — The parent ships identity, never contract.** A spawned child
  receives its session id and workspace binding; task, role, and lineage
  are read child-side from the durable edge. **Secrets never cross the
  specialization channel** (§3.2): credentials are re-resolved child-side
  from the credential store. A child argv carrying a prompt, or a wire
  message carrying a credential, is a finding.
- **L9 — The engine never names a process.** Materialization and
  cancellation of delegations are abstract capabilities injected by the
  composition root; no `lib/agent` code names a pid, socket, or
  heap-shared child value.
- **L10 — The pool holds no workspace-derived state.** A pooled process is
  shared-ready and workspace-blank; nothing in it can drift from a config
  file (Method rule 2 made structural).

## 2. Concurrency model (stated once, load-bearing)

**Mentat is single-domain, and stays single-domain under this RFC.** No
`Domain.spawn` exists anywhere in the tree; systhreads share the runtime
lock. The daemon's broker is fibers on the main domain, so its admission
counters and pid tables get the same atomicity the engine scheduler
already relies on ("controller fibers of one domain never suspend across
check-then-update", `lib/agent/scheduler.ml:31-32`) — no mutex, no
`Atomic`, provided broker updates keep the same non-suspending discipline.
Any systhread that must touch broker state (there should be none — reaping
is fiber-native, §7.3) must be named and protected explicitly.

This also re-grounds the exec-fresh argument (§6): the reason
fork-without-exec is rejected is **not** multi-domain fork UB (mentat is
single-domain) — it is that a forked child would share the parent's
`Mirage_crypto_rng` state (two processes emitting identical "random" bytes
— a TLS/PKCE security defect), duplicate the Eio backend's kernel-facing
state (io_uring/kqueue fds, the systhread pool), and share the store lock
fd, voiding the fence. Every child boots by `exec` and re-seeds.

## 3. The child process

### 3.1 What it is

A `mentat` process that serves exactly one session — its own — over the
RFC 0017 wire, and exits when its work settles and its feed closes. It
opens its own store handle to the shared root (legitimate cross-process:
POSIX record locks conflict *across* processes; the one-store-handle rule
is a within-process rule, `bin/composition.mli:71-83`); creates-or-attaches
the child session (idempotent); holds the child session's run fence; mints
the deterministic first turn from its own durable edge exactly where
`observe_delegation` mints it today — **relocated, and pinned by its own
golden** (the subtlest correctness point in the design: the child-serve
boot must mint the identical first-turn id and prompt the in-process path
mints, `mentat_agent.ml:469-484`); drives through `delegated_execution
~role` with role read from the edge; and serves feed + commands. The
topology is bidirectional: the daemon is the child's serve client, and the
child's own composition connects back to the daemon's broker for any
delegations *it* makes (§7.2).

A run-and-exit child observed only by `waitpid` was considered and
rejected: a live child must be commandable (interrupt, decision answers
from any frontend) and followable (drill view) while running, and
`route_session` + all-broadcast already provide exactly that for a served
session.

### 3.2 Specialization

The broker spawns a worker with a control channel; the worker reports
`{pool_ready; pid; binary_version}` (mismatch refused). On demand the
broker sends the specialization — session id, workspace root, the parent
instance's **resolved non-secret configuration and trust verdict**, model
selection — and the channel upgrades in place to the serve wire (the
recommended framing; a spike confirms, open question 3).

Two honest costs, named:

- **A new total serializer for the resolved view.** `Config.Resolved.t`
  has readers and a redacting diagnostic projection, but no full wire
  codec — the config layer was deliberately built so **no wire form can
  carry a secret** (`lib/config/mentat_config.mli`). This RFC keeps that
  law: the specialization payload is a new, version-gated codec over the
  *redacted* resolved view (provenance included, so the who-resolved
  firewall stays auditable), and the child **re-resolves credentials
  child-side** from the credential store/env exactly as any composition
  root does. Shipping the resolved view preserves today's semantics —
  in-process children run under the parent instance's resolved config, and
  a child re-resolving general config from disk could diverge mid-session;
  credentials are the narrow, acceptable exception (secret-bearing, rarely
  edited mid-session, and architecturally barred from the wire).
- **Parameterizing the engine.** `observe_delegation` is a callback field
  today (`mentat_agent.ml:410-420`), but the materialization *policy* —
  `Fiber.fork ~sw:t.sw` — is hardcoded in the hub (`:483`), and
  `Mentat_agent.create` takes no materializer. The injection seam (L9) is
  an additive engine-signature change, not a wiring-only change.

## 4. Failure taxonomy across the boundary

Governing rule (L5): reap for liveness, read the head for outcome, let the
child's own total `recover` settle. The parent never fabricates a terminal
from an exit status.

| Scenario | Settlement |
| --- | --- |
| Exit 0, head terminal | the committed result answers the wait |
| Nonzero exit, head terminal | the committed result stands — nonzero exit is not Ambiguous by itself |
| Any death, head shows an open claim | the child's own `recover` (in a successor process) settles: open tool → Ambiguous, turn continues; open provider → Ambiguous → Interrupted; a recorded interrupt forces Interrupted (D11) |
| Death **before any effect** (empty head, session created or not) | idempotent re-spawn (L4) — a new matrix row the in-process design never needed; nothing to recover, nothing lost |
| Killed by signal (preemption, OOM, rlimit) | as the open-claim row; a SIGKILL is not a settlement kind |
| Parent dies, child alive | the child keeps driving its own fenced session (a sibling, not an OS-nested dependent); parent restart re-derives edges and re-binds — live child observed, settled child read, absent child re-driven |
| Both die | each session recovers independently from journals; content-derived ids make it registry-free |
| Child alive but cooperatively uninterruptible | the ladder (§5) reaches SIGKILL; the open claim then settles Ambiguous — a *settleable* claim, never a result |
| Child journal unreadable beyond torn-tail repair | the honest-ambiguity floor: the parent settles the wait's slot Ambiguous and never re-spawns (prior effects of unknown extent). *Implementation caveat:* today's `ensure_child_session` routes a store-read error to spawn-failure text (`mentat_agent.ml:457,502`); the process backend must preserve the no-re-run guard while carrying the Ambiguous label the law requires |

The rule's teeth: an exit code, a signal number, and a hang are none of
them grounds to retry. Process death does not create ambiguity; it reveals
what the head already implied. Under partition (§9), the parent's wait
simply stays parked — `Unavailable` is a routing-layer error a *frontend*
may see, never a settlement kind (L5 corollary).

## 5. Preemption

The ladder — rungs 0–2 target the child's driver process; rung 3 targets a
child's own tool descendants, never the delegation tree (L3). Rung 3 also
narrows RFC 0011 §11's *second* wound (leader-only cleanup), distinct from
the systhread wound rung 2 closes.

| Rung | Mechanism |
| --- | --- |
| 0 | cooperative: durable `Interrupt_requested` + flag + per-effect `Switch.fail` (today's `interrupt_worker`, routed over the wire) |
| 1 | SIGTERM + bounded grace — the child runs its own durable-first close if it can |
| 2 | SIGKILL the child process; the OS releases its fence; a successor `recover` settles |
| 3 | group-kill of a child's tool descendants (child under `setsid`; `killpg`, or `cgroup.kill` on Linux, which double-forks cannot escape — the macOS residue is named, not claimed dead) |

**Authority:** the model may request rung 0 only. Rungs 1–2 are policy or
user — never the model, which could otherwise silence a child about to
settle an inconvenient result. Rung 3 is automatic, owned by the child's
own workspace-io at tool termination.

**Pid discipline.** The broker spawns via raw `create_process` (no
Eio-managed spawn across the daemon's switch topology), so the
pid-reuse-safe reap of `otherlibs/subprocess` is not available here.
The ladder and the reaper therefore share one serialized broker fiber:
death clears the pid from the ladder's target set in the same
non-suspending step that observes it, and no signal is ever sent to a pid
after its reap. Where the platform offers a handle (Linux `pidfd_send_signal`,
macOS `kqueue EVFILT_PROC`), the broker uses it as the stronger form.

**Honesty improves, precisely:** when the group is proven dead (group
reap, or `cgroup.kill`), the child's Ambiguous settlement may drop
possibly-still-mutating — the design proves more; it does not claim more.

## 6. Boot cost, exec-fresh, and the (gated) warm pool

The only irreducible per-cold-child cost is the process-global tier — RNG
seeding and CA-bundle decode (~65 ms, `lib/provider_runtime/tls_setup.ml:
44-45`) plus exec/syspolicyd — and the per-child role-capability seal
(`lib/workspace_io/mentat_workspace_io.ml:401`); everything else is
shareable (store handle, runtime) or shipped at specialization (workspace
resolution). Exec-fresh is mandatory (§2), so only pre-booted processes
can amortize the process-global tier.

**The pool is a latency optimization, and it is gated on evidence.** The
killable child is fully correct at N=0 — every child cold-execs at
~100–200 ms. Whether that latency is *felt* depends on spawn frequency
nobody has measured, and a shared-ready worker's resident cost (a 45 MB
static binary plus decoded CA store and runtime — plausibly 60–120 MB
RSS, unmeasured) is real on laptop-class hardware. Therefore: **N=0 is the
default until a measured spawn-rate/latency witness and a measured worker
RSS justify residency** — the same measure-first discipline the rest of
the design applies. The pool's principles are pinned now (a pooled worker
is shared-ready and workspace-blank, L10; one session per worker, then
exit — reuse would leak session state and defeat crash isolation; N
configurable, N=0 correct); its tuning (refill, eviction, sizing) is
implementation detail the RFC deliberately does not fix.

Admission and latency never conflate: capacity gates *whether* a child may
run; the pool gates *how fast* it starts; a granted spawn with an empty
pool cold-execs.

## 7. The broker and the seams

### 7.1 The injection seam (L9)

The composition root supplies materialization: single-process CLI →
today's sibling fiber, unchanged; daemon → the broker (admit → spawn or
checkout → specialize → connect → register → observe). Requires the
additive `Mentat_agent.create` materializer parameter (§3.2).

### 7.2 Admission

The per-parent semantic cap stays in each driving engine's scheduler,
unchanged — in daemon mode the *root* parent's engine lives in the daemon,
so its reservations are local. A child process reserves its own children's
semantic slots locally, but every **process** admission — at any depth —
goes through the daemon broker's counter over the child's broker
connection, so the daemon remains the single process-admission authority
tree-wide (the reserve call reappears as an RPC for depth ≥ 2; only the
root's dissolves). The broker counter is journal-rebuildable, unpersisted,
and decremented on every reap (L7). Whether it needs sub-policies beyond
one number is an open question; one number ships.

### 7.3 Observation: three duties, one invariant

- The **feed observer** (a broker fiber following the child's feed) fires
  `note_settled` into the parent's scheduler when the terminal fact
  streams — the latency path.
- **Reaping is fiber-native and load-bearing for liveness** — and it
  *drives settlement*, not merely observes it. On death the broker runs
  the single-edge equivalent of `rebuild_children`: terminal head →
  `note_settled` + deliver; unfinished head → re-materialize a successor
  (whose `recover` settles the open claim); empty head → idempotent
  re-spawn. This closes the window the feed alone cannot: a child killed
  between its journal commit and its feed emission, or dead before ever
  serving — without it, the parent parks forever. A systhread `waitpid`
  is forbidden here for the same reason the codebase already bans it in
  workspace-io ("never a systhread waitpid, which would pin the owning
  switch's release", `mentat_workspace_io.ml:1560-1562`).
- **`rebuild_children` on parent recovery** remains the backstop that
  re-derives everything from journals.

Double delivery is benign by construction and stated so: `note_settled`
is a keyed replace, release a keyed remove, deliver a wake — all
idempotent over the same journal-derived `child_result`.

### 7.4 Registration, orphans, and daemon restart

Child processes register **session-keyed** beside the workspace-keyed
instance registry (the root-keyed lookup would resolve a child to its
parent's instance). The registry is in-memory; a daemon restart loses
every serve endpoint — so a child's serve endpoint is **derived from its
session id** (a well-known per-session socket path), letting a restarted
daemon re-discover live orphans. On re-materialization meeting a held
fence, the broker **binds as an observer of the live child** — today's
in-process path would route `` `Held`` into `fail_spawn`
(`mentat_agent.ml:211-212, 459-460`), settling the parent's wait as
spawn-failed while a live child computes the real result; the process
backend must not inherit that arm (L4).

**Idle-sweep discipline:** the daemon's three-zeros sweep is
connection-based and cannot see a child's internal activity; sweeping a
working orphan would SIGKILL recoverable work. A child entry's idle
predicate is therefore *settled + empty durable queue + no active turn*,
queried from the child — distinct from the instance predicate.

**Visibility under unreachability:** ephemeral flags (`possibly_mutating`,
faulted phase) are process-local; when a child is unreachable the parent
must report `possibly_mutating = true` conservatively — never the
routing-layer default `false` (`bin/daemon.ml:249-254` as it stands) — on
the exact "is it safe to act" signal.

**Crash-loop visibility (wound 3), without a crash apparatus:** if a
re-spawned child id faults again within a short window, the broker holds
an in-memory intensity count surfaced at attach. Ephemeral, mints no fact,
throttles nothing.

## 8. Per-child confinement — additive, not gating

Kernel sandbox tightening: explore/review/verify children launch under a
no-writable-roots, no-network Seatbelt/bwrap profile — kernel-enforced
defense in depth under the catalog, sealed from the child's role contract
(reconstructible on re-spawn, L1-safe), monotone (a child may only be more
confined than its role's policy). Recommended as the default for the three
read-only roles at the rung that ships processes; generic children keep
their resolved profile, never loosened. Resource limits (rlimits, nice,
cgroups where present) compose with admission: the permit is the logical
bound, rlimits the physical one; a breach is "killed by signal" (§4).
None of §8 gates the killable child; all of it is enabled by it.

## 9. Remote children — invariants only

The remote consumer satisfies the milestone's product clause, on the
RFC 0017 §7 public-bind substrate (itself a named future with its own
consumer). This RFC pins only the invariants that make remote a
location change rather than a redesign: the child's journal is the truth
*where the child runs* (the parent persists only its delegation edge and
re-derives `child_result` over the wire — same law, different reader);
D17 holds via the remote fence; all-broadcast makes a remote child's
`Decision_requested` one more hop, wire shape unchanged; partition parks
the wait (never a settlement), and worker death settles from whatever the
child journal reached. Everything else — topology, provisioning, checkout
sync, discovery, fleets — is the remote rung's own design, with its ops
burden (a second host a maintainer must run, sync, version-match, and
monitor) stated there honestly, not prepaid here.

## 10. Staging

- **Precondition (owned by RFC 0017, not ruled here):** the daemon as the
  standard interactive runtime is RFC 0017's explicitly deferred Stage-3
  decision, with its own support burden (stale daemons, token lifecycle,
  version skew). This RFC *requires* it as the milestone gate's clause (a)
  and takes no position on when — carrying no default-flip inside.
- **The core rung — killable local child (this RFC).** Child-serve boot
  mode; `Child_backend` seam (`In_process | Local_child`; `Remote_child`
  is the named extension the remote rung adds); session-keyed
  registration + derived serve endpoints; broker (admission, spawn,
  observe, reap, ladder); specialization with the resolved-view codec;
  read-only-role kernel profiles. Preparatory mechanical step, landable
  early as a pure refactor: the backend seam with only `In_process` wired,
  gated by the normalized-identical golden. **Pool at N=0.**
- **The pool sub-rung — evidence-gated.** Lands only with a measured
  spawn-rate/latency witness and a measured worker RSS (§6).
- **The remote rung — named future.** §9's invariants; its own design when
  a consumer forces it.

Test gates, blackbox-first per house norms: the spawn→wait→integrate
golden identical across backends **after normalization** (timestamps,
durations, usage, pids, socket paths censored; the content-derived session
and first-turn ids are stable across backends and asserted verbatim — the
first-turn mint golden is called out as the high-risk pin); preemption
reaching SIGKILL + group reap; child SIGKILL mid-turn → Ambiguous, with
possibly-mutating dropped iff group-proven-dead; parent-crash rebuild with
no lost result; daemon-restart orphan re-bind (the `Held`→observer arm);
admission-counter rebuild + decrement-on-reap property.

This RFC pins design at the milestone; it schedules nothing. Implementation
remains gated behind the maintainer's milestone triggers and does not
preempt the roadmap's current phases.

## 11. What this RFC rejects, with reasons

- **A supervisor-spec DSL / restart strategies / intensity governors.** No
  referent: children are sequential at-most-once effects; the engine has
  one total recovery policy. Laws, not a framework.
- **fork-after-init / a pre-forked CoW pool.** Shared RNG state is a
  security defect; the Eio backend's kernel-facing state does not survive
  fork; a shared store fd voids the fence (§2). Exec fresh, always.
- **Exit-code-as-outcome; OS-signal settlement kinds.** L5.
- **`killpg` as delegation cancel.** L3 — the semantic graph is not the
  process tree.
- **Eager heartbeats / parent-death watchdogs / orphan-killing.** Silence
  is not death; settle-then-idle is the orphan bound; lazy re-bind is the
  restart discipline; always-on deployments use the OS supervisor.
- **Durable crash facts.** The Ambiguous settlement is the crash report at
  the right altitude; only the ephemeral intensity lens ships.
- **Hot code upgrade.** Journal-first durability makes restart lossless —
  a celebrated OTP mechanism mentat is structurally stronger without.
- **An RPC result channel for child outcomes.** L5; the wire carries feed
  and commands, never the authoritative result.
- **Per-child OS threads.** Not independently killable — that *is* the
  systhread wound; reintroduces the shared heap (L2).
- **Container-per-child.** Seconds-scale tax for isolation the sandbox
  capability provides at ms-scale; a worker may itself run in a container
  — ops, not machinery.
- **Always-daemon; parent-as-process.** Single-process CLI with in-process
  children stays first-class forever.
- **A secret-carrying specialization codec.** The config layer's
  no-secret-on-the-wire law survives the boundary (L8); credentials
  re-resolve child-side.
- **The SQLite listing/routing index as a companion deliverable.** RFC
  0017 reserves that sanction explicitly ("not this RFC's sanction to
  build") and conditions it on *measured* listing latency; this RFC only
  notes that child-session multiplication may one day be that evidence
  (open question 5).
- **Worker reuse; persisted permits; a second child-journal store;
  frontends connecting to children directly; a workspace-warm pool as
  default; a distributed scheduler.** Respectively: crash-isolation leak;
  L7; L5/D16; the single-auth-edge rule (RFC 0017 §7); config-staleness
  drift (L10); no consumer.

## Open questions

1. **OS parent of a local child** — the daemon (uniform reaping;
   recommended: the OS tree and the delegation tree then never coincide)
   vs a per-instance supervisor fiber.
2. **Rung-3 generalization** — group-aware tool cleanup for all drivers at
   this milestone, or children first? Recommendation: generalize; children
   are merely the forcing consumer.
3. **Specialization channel framing** — in-place upgrade to the serve wire
   (recommended: one fd) confirmed by spike.
4. **Local settled-result read** — the daemon's own store handle vs
   uniformly over the child's serve wire. Measure at the core rung.
5. **Index evidence** — whether child-session multiplication produces the
   measured listing/routing latency RFC 0017 §4 waits for.
6. **Cooperative-interrupt delivery to a child process** — SIGTERM-as-
   notification vs journal polling at safe points; the signal likely
   suffices (the uncooperative case escalates anyway).
7. **Broker admission policy** — whether the daemon-wide process counter
   ever needs sub-shares (per-workspace fairness); one number until a
   starvation witness.

---

Filed independently of this RFC (real today, one-line fix): the LLM
transport re-derives the RNG generator and CA authenticator per request
(`lib/llm/http/transport.ml:70-74`) instead of using the memoized
`tls_setup` path — ~65 ms of avoidable latency on every provider call.
