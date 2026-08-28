# RFC 0026 — The broker layer

- Status: published
- Author: mentat campaign
- Date: 2026-08-27
- Amends: RFC 0018 (subagent processes — resolves its open question 1
  on the broker's placement, revises L9 as stated in the supervisor
  section, and executes the `In_process` deletion whose trigger RFC
  0024 §13 carries), RFC 0024 §9 (routine runs become served sessions)
  and its repo-layout ruling (lib/ gains one library, ruled below),
  RFC 0000 §3 (the process model)

## Summary

One shared library gives every mentat process the same two abilities:
supervise the agent processes it spawns, and send messages to other
agents. An agent is a session; its id is its address; its process is an
activation — one `mentat serve-session` process serving the session
over a socket derived from the id, holding its run fence, exiting when
idle. Every process supervises the sessions in its own table; mentatd
is the same library plus root policy and nothing else. A message is a
queue entry delivered into the target's journal — over the target's
socket when a driver serves it, by a brief labeled fence-held append
when it is dormant. There is no registry, no routing layer, no new wire
command, and no second mailbox. Today's parent-to-child delivery
becomes the send's first caller; the in-process subagent backend, the
daemon's engine hosting, and the routine one-shot spawn are deleted.

## Motivation

The consolidation audit (2026-08-27) found ten kinds of process where
the product's own laws admit four, eight signal-escalation ladders, six
exit policies, two supervisors sharing five copied primitives, and four
run shapes of which one can serve a socket and three are deaf. Subagents
are OS processes in exactly one of four cases. Routine runs cannot be
watched, attached, or messaged, and if their spawning process dies,
nobody enforces their budget. Parent-to-child messages ride a five-arm
liveness ladder with a documented silent-drop window.

The maintainer's five rulings fixed the target, and this document cites
them by name:

- **the one-process-kind ruling** — every agent run is a session served
  over its own socket;
- **the own-children ruling** — every process supervises its own
  children, with one supervisor library;
- **the separation ruling** — mentat never connects to, spawns, or
  names mentatd;
- **the one-connection ruling** — every consumer reaches a session by
  dialing its socket directly; no forwarding layers;
- **the scheduler-only ruling** — mentatd hosts no engine and parses no
  untrusted text.

This RFC is the design of the layer those rulings imply. If we do
nothing, every future feature — inter-agent messaging is already
mandated — picks one of the ten process kinds to grow on, and the count
becomes eleven.

## Guide-level explanation

*As if it already shipped.*

**An agent is a session.** Everything about it derives from its session
id: its journal (the truth), its socket path (the door), its run fence
(one driver at a time). When a session needs to run, some process spawns
`mentat serve-session --session ID --cwd DIR` and watches the pid. That
is the only way any agent runs — your interactive session, a subagent,
a routine's PR review. The process exits when the session is idle; the
session remains, durable, addressable, resumable.

**You never think about which binary hosts what.** `mentat` spawns and
dials the session you are driving. mentatd spawns routine runs when
webhooks arrive and re-adopts survivors after a restart. The web page
dials the same socket the TUI dials. If mentatd restarts, your sessions
keep running; if your terminal closes, your session's process notices
the connection drop and winds down on its own idle clock — or keeps
working, if it still has work.

**Agents talk by mail.** Inside a session, the model calls one tool:

```
send { to: "parent", message: "the scan finished; two findings attached" }
```

`to` is a handle the session can prove from its own journal — `parent`,
one of its own spawned children by name, or a contact it was granted.
The message lands in the target's durable queue and the target reads it
as input at its next turn boundary, with the sender named. A dormant
target keeps the mail in its journal until something runs it. Mail
never interrupts a turn, never answers a permission ask, and never
starts a process by itself.

**Waking is separate from sending, on purpose.** "Do this now" is two
acts: send the message, then ensure the target's process is running. A
parent may wake its own children. mentatd may wake a routine session
inside its budget. Nobody else's mail can make your agent spend money.

**The human uses the same primitives.** `mentat session send ID "…"`
mails any session you own. Attaching your TUI to a running routine
review — including one parked on a question — is dialing its socket,
which exists because every run serves one.

## Reference-level explanation

### The activation

`mentat serve-session --session ID --cwd DIR [--spawned]` is the one
boot. No mode flags: the boot reads the session document and derives
the shape —

- a delegation edge (`delegated_from`) → resolve the edge, mint the
  deterministic first turn from it, confine the socket's session cone
  to the delegation subtree (today's behavior, byte-for-byte; the
  `--interrupted` carry stays with this shape);
- a routine-born session → apply the routine's recorded run policy —
  mode, sandbox, step cap, output schema, and the model, reasoning,
  and permission spellings — from the store; the wall clock is not
  recorded: it is the supervising fire's deadline (§ the supervisor —
  one budget must not have two clocks);
- a plain root session → serve plainly; confinement is "this session
  and anything it delegates."

**Every shape attaches its driver at boot.** Attach runs the driver's
queue admission, so mail already in the journal starts the first turn —
this is the seam by which send-then-supervise runs a routine's trigger
prompt, and what makes "booting" a true word in the serving law.
Delegation already satisfies the rule through its first-turn submit.

Shared by all shapes (already built): socket derivation with 0700
parents, listen/serve with the 1 s heartbeat, connection counting,
`setsid` under `--spawned`, the two-signal stop seam, the idle watchdog
with linger, durable-first shutdown. The idle predicate is: settled
head, empty queue, all children idle, zero connections — sustained for
the linger. A frontend that wants a session warm holds a connection;
`active > 0` is the lease. Nothing else decides when an activation ends.

### The supervisor

The existing broker family — the WNOHANG reaper, the escalation
ladders, the spawn helper, the pure decision tables — moves from
`bin/mentatd/` into a new first-class library, **`lib/broker`**
(`mentat_broker`), and loses its delegation-only assumptions. This
revises the campaign's earlier "lib/ gains zero new libraries" ruling,
deliberately and for this one subsystem (maintainer, 2026-08-27): the
broker is a real library with its own vocabulary — spawn, watch,
send — consumed by both binaries and by the engine directly.
Deployment facts are threaded as configuration at construction, the
way every library receives its environment: the executable to spawn,
the socket base, the rendered environment, the log directory. The
library knows no binary by name and reads no ambient variable. The
surface (shape, not final signature):

```ocaml
(* lib/broker/broker.mli — linked by both binaries and by the
   engine. *)
type t
(** One broker per process: the child table, the reaper fiber, the
    observers, under the process's switch. Children deliberately
    outlive the switch; a successor re-adopts them. *)

val create :
  sw:Eio.Switch.t -> spawn_bin:string -> socket_base:string ->
  environment:(string * string) list -> log_dir:string -> t
(* Deployment facts are arguments, resolved by each binary's own
   surface (flags, config); never ambient environment. *)

type failure_sink = reason:string -> unit
(** Where a given-up child's failure lands. The engine's sink settles
    the delegation in the parent; mentatd's root sink writes the run
    receipt and alerts. Every [supervise] names its sink: a silent
    failure arm is unrepresentable. *)

val supervise :
  t -> session:Mentat_session.Id.t -> cwd:string ->
  ?deadline_s:float -> ?respawns:int ->
  on_settled:(unit -> unit) -> on_failure:failure_sink -> unit
(** Idempotent per session. Probes the fence and interprets the
    decision table: a holder serving the socket is adopted and
    observed; a custodial holder (a labeled brief hold — a send
    append, a store removal) is a transient, re-probed briefly, never
    preempted and never failed; a free fence with unfinished work — an
    unfinished head OR unconsumed queue entries — spawns the
    activation; a free fence with a terminal head and an empty queue
    calls [on_settled] directly; a preemptable stale holder is
    laddered, then respawned. Respawns are bounded (default 2 for
    delegation children, 0 for routine runs); exhaustion fires
    [on_failure]. *)

val cancel : t -> Mentat_session.Id.t -> unit
(** The ladder — wire interrupt, grace, SIGTERM, grace, SIGKILL — for
    sessions in this broker's own table only. (Named [cancel]: [stop]
    is the broker's own teardown.) *)
```

Supervision recurses: an engine's `spawn` verb materializes the child
through its own process's broker; a serve-session process therefore
supervises its session's delegation children as processes, at every
depth. mentatd holds one broker for its roots.

**Observation.** The supervisor's read-only sibling: `Broker.watch`
observes a session *without* owning it — the fence, its owner label,
and the journal head, until the head is terminal — the monitor to
`supervise`'s link, in OTP terms (exact signature at contact). It
unifies three hand-rolled copies of the same probe loop: the broker's
own internal foreign watch, routine reconcile's pending-run probes,
and the dashboard's fence probes. `Broker.children` is the matching
introspection query — the supervised set as (session, pid, state).
Both are built at the rung reconcile consumes them (R2–R3), not
before.

**The engine depends on the broker directly** (maintainer-ruled,
2026-08-27): `lib/agent` links `mentat_broker` and calls
`Broker.send`/`Broker.supervise` at its delegation sites. The
`Ports.child_backend` variant, the `child_ops` closure record, and the
in-process fiber backend are all deleted — the injection seam existed
to keep processes out of the engine, and the ruling is that one hop of
indirection is not worth that purity. RFC 0018 L9 is revised
accordingly: the engine names no pid and dials no socket *itself* —
process mechanics live behind the broker's surface — but the engine
names the broker. Consequence for tests, settled
with the same ruling: the broker itself carries the one test seam — a
small constructor building a mocked broker whose spawn and dial
effects are stubbed (`Broker.for_tests`, shape decided at contact) —
so unit-tier delegation tests stay fast and deterministic without any
engine-side indirection, and the mock lives beside the one real
implementation it mocks.

The same unfinished-work judgment — head **or** queue — replaces the
bare settled-head read wherever a settlement is derived (the parent's
rebuild, the broker's integration): a child with unconsumed mail is not
finished, so a `follow_up` to a settled child re-runs it instead of
settling the delegation against the pre-mail result.

The deadline has one home: the supervisor's ladder fires at it. An
orphan whose supervisor died is not deadline-enforced until re-adopted;
its backstops are its own idle exit and, for routine runs, the
reconcile fold at the node's next pass. (The earlier draft claimed
child-side self-enforcement; one budget must not have two clocks.)

Exit handling keeps RFC 0018's law: exit is liveness, the journal head
is truth. `on_settled` is fired after a head-and-queue read, never from
an exit code.

### The send

```ocaml
(* the origin lives in lib/session (the wire and the journal encode
   it); the broker consumes it. *)
type origin =
  | Agent of Mentat_session.Id.t
  | Trigger of { source : string; digest : string; key : string }
(* An absent origin means the owner — the human. There is exactly one
   spelling of "the owner sent this": absence. *)

val send :
  t -> ?origin:origin -> target:Mentat_session.Id.t ->
  id:Mentat_session.Queue.Id.t -> input:Mentat_llm.Content.t list ->
  [ `Delivered | `Undelivered of string ]
```

A message **is a queue entry** — the same entry, the same idempotent
admission (whose receipts survive consumption), the same turn-boundary
consumption as queued input today. The entry gains one optional member,
`origin`; the wire's `Queue_next` gains the same optional member. No
new command, no new mailbox.

Delivery is one bounded loop, decided by the fence's owner label:

0. **A target the sending process itself drives** (its own driver
   registry) is submitted locally. This arm is transitional: it exists
   while in-process drivers exist and is deleted with them at the
   eviction rung.
1. **Try to acquire the target's fence under the custodial label
   `send`.** Acquired → the target is dormant: perform the driver's
   admission exactly — the dedup, the accept table, the cap — commit
   the enqueued fact through the store's ordinary path, release.
   `` `Delivered ``. (Acquisition *is* the liveness probe; there is no
   read-then-act race.)
2. **Fence held by a serving label** (the child server's
   `serve-session`, or the transitional serve-mount) → dial the
   derived socket, submit `Queue_next` on a short-lived, grace-bounded
   connection. The driver's dedup makes redelivery idempotent.
3. **Fence held by a custodial label** (`send`, the store's `remove`)
   → another brief hold is in flight; re-probe on a short backoff.
   Never dial, never preempt.
4. **Budget spent with the fence held throughout and no delivery** →
   `` `Undelivered ``, against the sender's durable record.

The budget is the caller's: the model tool and the CLI use the short
grace (seconds — a tool call must answer); a supervisor delivering as
part of a wake may wait the boot budget. A holder that exits mid-loop
is caught by the next pass's acquire — the loop is symmetric, and
deliverable mail is never parked by a transition in either direction.

The activation's first attach tolerates a custodial hold: a fence held
under `send` at boot is retried briefly, not treated as a foreign
driver. (This, the custodial arm of the decision table, and the
serving law's wording below are one change — the three sentences land
together.)

**Sending never wakes.** A queue entry admitted by a live driver
against an idle session starts a turn through the ordinary loop. A
dormant session's mail waits. Waking a dormant session is `supervise` —
a distinct act by whoever holds supervision authority: the parent for
its children (`follow_up` means send **then** supervise), mentatd for
routine sessions whose routine declares the `agent_message` trigger,
the human for anything. mentatd's wake scan is the node's existing
sweep: it enumerates routine-born sessions whose routine declares the
trigger, reads unconsumed origin-bearing entries fence-free (the
observation posture), and fires through the ordinary budget-fenced
path — a wake bought by mail spends the routine's fire limits exactly
as a webhook fire does; mail can never buy more runs than the trigger
policy allows.

**Trigger provenance reaches the turn.** Queue admission carries the
entry's origin into the turn it starts: an entry with a `Trigger`
origin mints the turn as `Triggered` (recording the entry id), and a
routine-born session's admission applies the routine's recorded
contract — mode and output schema at admission, the step cap through
the boot's overlay — never the plain Build defaults. This is the
second journal-encoding change (§ wire and store) and what keeps
receipts, projections, and the triggered discipline working when the
trigger prompt arrives as mail.

**The receiver's experience.** Queued input at a turn boundary. The
engine renders the sender's name into the prompt framing from the
typed origin — never from the body, so a hostile body cannot imitate a
better sender; the body is fenced as triggered input already is.

**The first caller.** Parent-to-child delivery re-expresses as: record
the verb call (unchanged — the durable receipt in the parent's
transcript), derive the id from the recorded position (unchanged
domain, so existing journals redrive through the new path), then
`send`; for `follow_up`, also `supervise`. Deleted outright: the
prompt-vs-queue delivery ladder, the busy-fallback, the in-process
attach fallback and its silent-drop window, and the broker's
gone-means-my-table-forgot arm.

**The second caller.** A routine fire becomes: create the run session,
`send` the trigger prompt (`Trigger` origin, entry id derived from the
trigger identity so a double fire dedupes), `supervise` with the
routine's wall clock and a zero respawn budget, fold the receipt in
the sinks. The one-shot spawn — prompt over stdin, jsonl capture, no
socket, no setsid — is deleted; a parked run is attachable and a live
run is followable.

**The third caller.** Child-to-parent reply: `send` with
`to: "parent"` — new capability, zero new mechanism. A child holds no
wake authority upward; the reply is mail.

**What re-drives an undelivered send** — by origin, honestly:

- *Agent sends on a delegation edge*: the existing triggers — the
  parent's next attach, and the observed child exit — sweep the verb
  receipts and re-send. Residue admitted: a parent that never attaches
  again, whose child exit no broker observes, leaves the send undelivered
  in its receipt; there is no standing sweep, by design.
- *Child-to-parent*: the child's own next activation re-drives; a
  child that settles with an undelivered reply leaves it in its
  receipt, and the parent integrates the settlement result instead.
- *Owner sends*: the returned `` `Undelivered `` **is** the handling —
  the CLI prints it and exits nonzero; nothing pretends otherwise.
- *Trigger sends*: a fresh run session's fence is free by
  construction, so the append arm applies; an undelivered trigger send
  is a race residue covered by the fire's receipt and the routine's
  next fire, which dedupes into the same entry id.

### Addressing and authority

A session id is the address, full stop. The socket path, journal, and
fence all derive from it; there is no registry and no name service.

Models never see raw ids. The `send` tool resolves handles against the
session's own recorded facts: `parent` (its `delegated_from`),
`child:<name>` (its own recorded edges — today's validation), or a
granted contact. An unknown handle is a failed tool call — an illegal
send is unrepresentable at the only surface a model has.

**A grant has one home and two writers.** A grant is a fact in the
*target's* journal naming a session that may mail it, written only by
the target's spawner at spawn (wiring siblings: the parent writes a
grant into each) or by the owner via CLI. No engine verb commits one:
an agent cannot widen its own address book, and the accept table
trusts grant facts precisely because only those two writers exist. The
sender's handle table is derived from grants naming it, read through
the lineage resolution attach already performs.

The owner's surface is `mentat session send <id> <text>`: an
owner-origin send to any session in the store, through the same
delivery loop.

**The accept gate** admits an entry whose origin is the target's
parent, one of its own children, the owner (an absent origin), its own
routine, or a grant-named session; anything else commits a durable
refusal fact and the content never reaches the model's context. The
gate runs in whichever process performs the admission: the target's
driver on the wire arm (a structured refusal for a rejected
`Queue_next`), the sender's broker on the append arm. On the append
arm this is etiquette, not enforcement — everything runs as one uid,
and any local process can forge any file; the gates are correctness
within the owner's own account, the same trust model as the store and
the fences. The gate that matters against prompt injection is the send
tool's address book, because an attacker inside a model has only the
tool surface.

Attribution is never authority: the origin is recorded and rendered
and grants nothing — RFC 0024's `triggered` discipline, promoted to a
law here. Decision authority remains human-only; mail cannot answer a
permission ask and cannot carry an interrupt — those are not in the
entry's type.

### Delivery semantics

- **Durability**: `` `Delivered `` ⇔ the enqueued fact is durable in
  the target's journal. There is no weaker success.
- **Idempotence**: ids derive from the sender's recorded position.
  Same send retried → same id → the admission dedups. At-least-once
  mechanics, exactly-once effect; no acknowledgement protocol.
- **Ordering**: per-sender FIFO; cross-sender order is arrival order,
  stated rather than engineered.
- **Backpressure**: a per-(target, origin) cap of **unconsumed**
  entries — deliberately a backlog bound, where today's per-edge cap
  was a lifetime bound; the rate law for paid wakes is the routine
  fire limit above, and the count runs at admission, under the
  target's fence, in both arms — which is what makes it race-safe. A
  full mailbox is a loud send failure. Entry size rides the existing
  byte caps.
- **Media** (landed adjudication, R1): `send` refuses inline and
  referenced media before either arm — inline bytes would enter the
  target's journal unexternalized, and a content reference names the
  sender's namespace, not the target's. The refusal is deliberately
  uniform across arms: deliverability must not depend on whether the
  target happens to be served. `Uri` media passes.

### Failure semantics

Every failure ends in a journal fact, a receipt, or a loud error — no
new settlement kinds:

| Failure | Outcome | Durable trace |
|---|---|---|
| activation crashes | reaper observes; respawn within budget re-serves the same session; `recover` settles open claims | child journal |
| respawn budget exhausted | the named sink: delegation → parent settlement; root/routine → receipt + alert | parent journal / receipts |
| parent process dies | children finish, self-idle, self-exit; mail and results wait durably; a dead run is folded at the node's next pass — a live orphan's deadline is not re-armed (the supervisor section's admitted residue) | child journals |
| mentatd dies | roots keep running and self-terminate on idle; boot rediscovery adopts live roots, folds exited ones | receipts, endpoint tree |
| send to unknown session | loud error / failed tool call | sender transcript |
| mailbox full | loud send failure | sender transcript |
| unauthorized handle | unrepresentable — the handle does not resolve | sender transcript |
| unauthorized origin at admission | structured refusal to the sender; the durable refusal fact is unresolved q2 — content never reaches the model either way | sender transcript |
| undelivered send | `` `Undelivered `` against the sender's record; re-driven per origin (above) | sender receipts |
| sender dies mid-append | fence releases on owner death; at worst the store's usual crash-truncated tail in the target's journal, healed at the next load | target journal |
| wedged orphan | idle exit; a dead orphan is folded by reconcile; a live wedged orphan is watched, never re-clocked — ending it is the owner's cancel | journals, fences |

The two silent arms today — the parentless failure no-op, and "settled
and orphaned look identical" — are structurally impossible: every
`supervise` names its sink, and unfinished work includes the queue.

### Wire and store contract

- **Wire**: zero new commands. `Queue_next` gains an optional origin
  member (additive; corpus extended). Commands still carry no
  principal; the origin rides the entry.
- **Journal** (the real compatibility surface), two changes landed,
  all decoder-first — old journals stay readable forever: the
  enqueued event gains the optional origin member; queue admission
  records the origin into the turn it starts (a `Trigger` origin
  mints a `Triggered` turn with the entry id). The third — the
  delivery refusal fact — is unresolved q2, unshipped.
- **Store**: nothing new. No spool, no registry files, no persisted
  grants store (grants are journal facts).

## Laws

- **L-B1 — An agent is a session.** Its address is its session id; its
  process is an activation with no identity of its own. Pids never
  cross any interface except the supervisor's own tables (0018 L9,
  widened from the engine to every interface). *Prevents:* registries,
  and every race a registry brings.
- **L-B2 — Whoever holds a session's fence *to drive it* serves its
  socket.** Serving holds carry a serving label — of which there are
  two, split by preemptability: the child server's label, the one
  holder the escalation ladder may signal, and the serve-mount label
  a live interactive host wears, dialable but never signalled (a
  broker must never ladder the owner's terminal). Brief custodial
  holds (a send append, a store removal) carry a custodial label and
  are bounded; the probe decides by label, never by bare heldness.
  The law binds fully once the eviction rung lands; since R-mail,
  interactive drivers and daemon-hosted engines hold under the
  serve-mount label and are dialable — an unlabeled holder is now
  only a host whose mount failed to bind, and the send's transitional
  local arm survives on same-process preference, not unreachability. *Prevents:* the unreachable
  driven session, and the misread of a millisecond hold as a foreign
  driver.
- **L-B3 — One boot, no modes.** The activation derives its shape from
  the session document, never from a flag that could disagree with it.
  *Prevents:* flag/document skew, and boot paths multiplying per shape.
- **L-B4 — Every process supervises exactly the sessions in its own
  table** — what it spawned or lawfully adopted (a parent its own
  children; mentatd only roots) — and signals only those. *Prevents:*
  the unsupervised orphan, and any process killing another's session.
- **L-B5 — Every supervision outcome lands in a named sink.** The sink
  is a required argument. *Prevents:* the silent parentless failure.
- **L-B6 — One send, no wake.** The messaging primitive is the queue
  entry; delivery never activates a dormant session. Waking is a
  supervision act by an authorized supervisor, and a wake bought by
  mail spends the target's routine fire limits. *Prevents:* mail as an
  execution vector, and mail as an unmetered budget drain.
- **L-B7 — Durable before delivered; the target's journal is the
  proof** (0024 N3's barrier, at the send edge). *Prevents:* delivery
  state living in memory, and un-journaled mail.
- **L-B8 — Attribution is never authority** (0024's `triggered`
  discipline, promoted to a law). The origin is recorded and rendered
  and grants nothing. *Prevents:* a forged sender becoming a
  capability.
- **L-B9 — An agent can name only addresses it can prove, and cannot
  widen its own address book.** Handles resolve against the session's
  own facts; grant facts are written only by the target's spawner or
  the owner. *Prevents:* the injected mesh, and the self-granted
  contact.

## Drawbacks

- An activation is an OS process with a real boot cost; subagents that
  ran as fibers pay a spawn each. The eviction rung's gate (below)
  measures it before the flip is irreversible.
- A burst of senders to one dormant session retries on its fence — the
  fence does not queue waiters; each sender's loop backs off and
  re-tries within its budget. Milliseconds each, but serial.
- The migration touches every process-shaped test in the tree; the
  golden rewrites are real review work.
- `follow_up` no longer starts the child's turn under a derived prompt
  turn id; the queue admission mints the turn. The wait and settlement
  machinery does not key on that id, but transcripts that pinned it
  change once.

## Rationale and alternatives

**The spool inbox (the strongest alternative).** One of the four blind
designs proposed a maildir-style spool per session: send = write a
file; the target drains it into its journal under its own fence. It
wins on sender simplicity — no fence contact at all — and its rejection
must carry its honest point: the spool never touches the fence, so it
never needs the custodial label this design adds. It loses on: a
second mailbox beside the queue (two stages, two dedup layers, a
drain, an accept-at-drain, a quarantine); un-journaled state (mail the
journal cannot see); and ~400 lines of machinery where this design
adds one optional member and one owner label. Three of four designs
independently converged on the journal-as-mailbox; the convergence is
the evidence.

**A wire send verb.** Promote the broker's delivery into a protocol
command with routing. Rejected: it needs a live process at every send
(the 30 s boot-wait and the silent-drop fallback exist because of
exactly this); it grows the wire; and under the separation ruling the
only shared router would be mentatd — a forwarding layer the
one-connection ruling forbids, over an edge the separation ruling
forbids.

**A resident message broker (real BEAM: registry + router).** Rejected
on the separation, one-connection, and scheduler-only rulings at once,
and on its failure mode: a router that holds in-flight mail must
persist it — at which point it has reinvented the journal with a
daemon in front.

**Messages wake their targets.** Rejected: waking is execution;
execution has owners, budgets, and sandboxes. A message that spawns is
a prompt-injection amplifier and an unbudgeted cost. The routine's
`agent_message` trigger is the governed exception that proves the
rule.

**Keep the in-process backend for interactive subagents.** Rejected by
the own-children ruling and on merits: it keeps two delegation stories
forever and makes the most-used path the least supervised.

**OTP imports declined deliberately** (from the exemplar study): links
(shared fate destroys recoverable work — sessions are durable);
selective receive (correlation is the `wait` verb over facts);
restart-strategy vocabulary beyond one_for_one (siblings share nothing
but the store); synchronous calls between agents (a blocking call
parks an OS process on another's model latency); hot code upgrade
(journal-first restart is lossless); transparent distribution (remote
stays RFC 0018 §9's named future). Adopted: the supervision tree,
monitors-not-links (death triggers a head read), the async
never-blocking send, the mailbox flow-control scar tissue, the restart
intensity bound.

## Non-goals

- Remote agents and cross-machine messaging (the fleet's relay rides
  the ingress seam, not this layer).
- A group/broadcast primitive; fan-out is the sender's loop.
- Agent discovery ("what sessions exist" is the store's listing).
- Priority mail, message deadlines, read receipts.
- Replacing the human decision surfaces: permission asks and their
  answering are untouched.
- Tool children (shell, git, the publish child — short-lived commands
  with a timeout and capture) are not broker clients: they have no
  session, no fence, and nothing to re-adopt. `Subprocess` remains
  their owner; the broker signals only the agent process, whose own
  `Subprocess` handles its tool-child group.

## Unresolved questions

**Before merge:**
1. RESOLVED at R1 (2026-08-27): the origin encodes as a small
   per-arm-tagged object, identical on wire and journal — the idiom
   the triggered turn already uses; a packed string would reopen the
   separator-injectivity hole over free-form ids. Two corpus goldens
   pin the bytes.
2. Whether the delivery-refusal fact is a new event kind or a payload
   of an existing notice kind (still open; R1 ships sender-side
   undelivered only).

**During implementation:**
0. `Broker.for_tests`'s exact shape (which effects are stubbable) and
   the delegation unit tests' migration onto it.
3. The append's exact store seam (the lifecycle twins' pattern vs a
   narrower entry point) — mechanical, decided at contact.
4. RESOLVED at R-mail (2026-08-28): the cap is 8 unconsumed entries
   per (target, origin) — a backlog bound, one named constant; the
   owner is never counted (the rate law aims at agents, and capping
   the human would regress their own queue); enforced in every
   delivery arm through the one admission judgment.
5. The handle grammar for granted contacts (`contact:<name>`?).
6. The custodial label's interaction with rediscovery's residue
   sweep — a `send`-labeled fence must read as transient there too.
9. The document-version gap the mail vocabulary opened: R1's origin
   member and R3's provenance, contract, and entry members are all
   additive optionals landed without a version bump (R1's precedent),
   so an old binary reading a trigger-born document fails on member
   decode instead of a clean unsupported-version refusal. Adjudicate
   once, for the whole vocabulary, before it widens further at R5.
   Note for that ruling: the run-policy members are deliberately
   textual — strings decode forever and refuse only where applied —
   so any future move to typed members must ride a version bump,
   never a decode change.

**Out of scope (tiered to their own work):**
7. The web frontend's dialing path (the eviction campaign's wave D).
8. The routine dashboard's mail view.

## Future possibilities

*The anti-ratchet rule: nothing here is a reason to accept this RFC,
nor a later one.* A mid-turn "check mail" tool; an
`agent_message`-triggered routine answering its own PR comments; a
mail view in the TUI side pane; remote delivery over the fleet relay
riding the same entry shape. A delayed send (`send_after`, "wake me
at T") is RFC 0024's `schedule` and `self_schedule` trigger arms
wearing mail's clothes — the durable record could ride the send, but
the firing belongs to the scheduler's beat; the anti-ratchet rule
applies.

## The ledger

Two bills, split by owner.

**The consolidation bill** — ruled before this RFC and paid with or
without it; this RFC only sequences it: the daemon's engine hosting
and routing proxy (~300), `find_or_spawn` and mentat's daemon
knowledge (~200, the separation ruling's bill), the in-process fiber
backend (~150 direct, ~250 with ripple — the deletion RFC 0024 §13's
trigger already carries), the routine one-shot spawn (~250, the
one-process-kind ruling's bill). Against it, the eviction campaign's
own additions (its ledger: roughly −270/+380 — a surface-and-residency
win, not a line win).

**The messaging bill** — this RFC's own ask: deleted, the delivery
ladder and its fallbacks (~200 measured); added, the send with its
arms and the append twin (~230), the tool verb and address book
(~180), origin plumbing and goldens (~130), the refusal fact (~50),
`mentat session send` (~80), the serve-mount bridge (~120, deleted at
the eviction rung), mentatd's wake scan (~100), the shape-reading boot
(~130). **Messaging is net positive, roughly +800, and is paid for by
the consolidation's deletions.** The honest headline is not a line
count: five concepts die — the second backend, the delivery ladder,
the routing layer, the one-shot run shape, the silent failure arm.

## Migration

Each rung ships green; "holds" means byte-identical. Acceptance of
this RFC implies nothing about priority or scheduling.

- **R0 — the move.** Broker family into the shared library; mentatd
  rewires. Pure move; everything holds.
- **Migration note, owned:** a pre-R1 journal whose follow-up was
  delivered as a derived-id turn holds no enqueued fact, so the
  narrowed redrive re-mails it once at the parent's next attach — the
  admission dedups everything after; bounded, once per old edge.
- **R1 — the send, first caller.** Parent-to-child delivery over
  `send` under today's topology — the transitional local arm carries
  in-process children; the ladder and fallbacks are deleted. The
  accept gate's base table (the owner, the recorded parent, the
  target's own recorded children; `Trigger` refused) lands at this
  rung in both admissions: one judgment in the session library, run
  by the target's driver on the wire arm and by the sender's broker
  on the append arm — the routine arm arrives with R3, the grant arm
  with R5. Holds: parent transcripts. Changes, named: the wire corpus
  extends for `Queue_next`'s optional origin member; child journals
  gain the origin member; messaging crams lose the fallback arms.
- **R-mail — the mandate ships. LANDED 2026-08-28.** The `send` tool
  verb with parent/child handles (replacing `send_message`; the
  retired spelling decoded forever), `mentat session send`, the
  backlog cap and sender framing this rung owned, and the serve-mount
  bridge: every in-process driver host — the TUI, headless runs, and
  the daemon — serves each driven session's socket under the
  never-preemptable mount label while driving, so a live parent is
  dialable. Delivers child-to-parent
  replies and human-to-session mail — the messaging mandate's core
  (sibling mail needs granted contacts and arrives with R5) — the
  messaging mandate — before any process-model risk is taken. The
  bridge is transitional and dies at R4. R-mail also owns the
  per-(target, origin) backlog cap — the first rung where non-kin
  mail can accumulate — and the sender-name prompt framing from the
  typed origin, which has no reader before foreign senders exist.
- **R2 — one boot. LANDED 2026-08-28.** Shape-reading serve-session
  with the attach-at-boot rule; routine and root sessions servable.
  Held: the delegated arm byte-for-byte. Landed adjudication: the
  boot derives two shapes, not three — a root attaches its driver at
  boot so journal mail starts the first turn and exits on idle by the
  finished judgment; the routine-born shape is honestly that root
  attach plus contract staging, which waited for R3's recording.
- **R3 — routine runs as sessions. LANDED 2026-08-28** (supervise,
  watch, children first; then the fire). Fire = create + send +
  supervise; the one-shot deleted; runs attachable; trigger
  provenance through queue admission. R3 also builds `Broker.watch`
  and `Broker.children` — the observation seam reconcile consumes,
  retiring its hand-rolled fence probes (the dashboard later). Held:
  receipts, the fold, run ids. Changed, named: the routine crams that
  pinned the one-shot. Landed adjudications: the recorded contract
  lives in session metadata — trigger provenance
  (`Metadata.Triggered_from`) beside the run knobs
  (`Metadata.Run_policy`), named members rather than an open field
  list, so the recorded envelope is exactly as wide as the grant;
  mail admission proves "its own trigger" from the recorded source
  and digest, so a policy edit strands no stale mail on the new run;
  a Triggered turn names the queue entry it consumed; a re-fired
  trigger with matching provenance adopts its run — the redrive law's
  fire arm; findings are read from the run's journal, never a
  captured stream; a bad output schema refuses before any spend; a
  parked run alerts at its wall clock, staying alive and answerable
  until then; a watch's `Gone settles recovered rather than skipping,
  because only a reaped line closes a pending record; and the
  reconcile settle is asynchronous — the boot-fold window between a
  watch's arming and its first poll is covered by the run-claim's dup
  authority, not by a synchronous settle.
- **R4 — recursion and eviction, gated.** Before this rung:
  measure activation spawn-to-socket and spawn-to-first-token, and
  run the process-heavy suites repeatedly; the RFC's gate is that the
  measured boot cost and suite wall-time stay within the bounds the
  maintainer accepts at that point. Then: engines materialize
  children via their own broker; `In_process` and the send's local
  arm deleted; mentatd sheds engines and routing; the TUI spawns and
  dials its own activation; `find_or_spawn` deleted; the serve-mount
  bridge deleted. The eviction campaign's waves C–E land here.
- **R5 — grants and the trigger.** Granted contacts, the
  `agent_message` trigger with the wake scan, the accept gate's grant
  arm.

R1 and R-mail are independent of R2–R4 and land first.
