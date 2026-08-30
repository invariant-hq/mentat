# RFC 0028 — The notification kind

- Status: `discussion`. (Lifecycle: `ideation → discussion → published →
  committed | abandoned`. `committed` means the document describes how the
  system works, not what we intend.)
- Author: mentat campaign
- Date: 2026-08-30
- Amends: RFC 0026 (the send — one entry kind becomes two; the
  unfinished-work, idle, and failure-clear judgments narrow to messages;
  unresolved question 9's version-gap adjudication widens to cover this
  RFC's optional members)
- Provenance: a twelve-question ground-truth audit, three blind designs
  (minimalist, clean-slate, laws), three adversarial lenses, one fold.

## Summary

Mail grows the second kind the maintainer ruled into existence: a
**notification** — an addressed, durable, attributed queue entry that
never mints a turn, never wakes anything, never keeps anything alive,
and folds — framed and fenced like all mail — into the next turn that
can carry input. Messages act; notifications inform.
Everything else is shared: the one delivery discipline, the one
admission judgment, the one cap, send-never-wakes. CR review feedback
is the first sender — today a composed CR reaches the agent by luck (a
file-change whisper, mid-turn only); after this RFC its announcement is
durable at send, on compose success, and reaches the model verbatim,
idle or live.
Workspace observations (build, lint, file-change, and the watch
supervisor's own advisories) deliberately do **not** migrate: they are
the session's own senses, pulled fresh at the engine's boundaries by
the drain road this RFC leaves byte-identical. No new commands, no new
event kinds, no new processes, no second mailbox.

## Motivation

Three pressures, one missing kind.

First, CR feedback rides nothing. The review cone writes the CR into
the source file and nothing tells the agent: the README's "delivered
live" claim is carried by an incidental fswatch notice that names the
changed path — not the comment — and only reaches a turn already
running. An idle session hears nothing, ever. The one delivery that is
plainly a communication from the owner to the agent has no road.

Second, the maintainer's ruling names a hole in the mail vocabulary:
"some deliveries are 'important' and start turns, others are just
notifications." Today the mailbox cannot spell the second half — a
queue entry always mints a turn (the admission ladder's `Queued` arm is
unconditional), so anything informational must either impersonate a
prompt and spend a turn, or stay off the mailbox entirely.

Third, the pressure will repeat. mentatd advising a session, a sibling
FYI under R5's grants, a goal-state change — each is a communication
that should not spend the target's money, and each would otherwise
arrive with its own bespoke channel, cap, and rendering. One kind,
built once, is the anti-sprawl move.

What this RFC deliberately does not do is the mandate's headline
reading — moving workspace notices onto the mailbox. All three blind
designs converged against it independently; the evidence is under
Rationale (the first alternative). The producer discipline the
maintainer asked for — "the watcher keeps state and never sends twice
for the same error" — is not a thing to build; it is the shipped
behavior of the settled-readings layer, and this RFC promotes it to law
on both roads.

## Guide-level explanation

There are two kinds of things in a session's mailbox, and the sender
declares which it is sending.

A **message** is "act on this." It is everything mail is today: the
owner's `mentat session send`, a parent's instruction, a routine's
trigger. Consumption mints a turn whose input is the message, framed
under the sender's name.

A **notification** is "know this." It is delivered exactly like a
message — durably, under the target's fence or over its socket, judged
by the same admission — but consumption never mints a turn. The entry
waits in the queue; when the target next starts a turn for any other
reason (a prompt, a message, a wind-down), the waiting notifications
fold into that turn's input, each labeled by its sender, and the turn's
record names what it absorbed. An idle target stays idle; a dormant
target stays dormant; nothing spawns, lingers, or bills for an FYI.

The owner's surface:

    mentat session send fix-auth --notification "heads-up: CI is red on main"

The TUI shows the entry as a dim, sender-labeled row in the queue strip
— unread mail, not a pending prompt — and it is not Esc-recoverable,
because it is not your prompt. When a turn folds it, it appears in the
transcript inside that turn's input, as a sender-labeled block.

The first real sender is the review screen. Composing a CR already
applies the edit through the review cone; on success the cone now also
sends the session a notification: "CR added — lib/auth.ml:412: <the
comment>". The file keeps the CR itself; the send is what makes the
*announcement* durable — it survives the session going dormant, and the
agent reads the actual comment, not a file path, at its next turn,
whoever starts it. Removing or resolving a CR sends the matching
notification.

And the line that keeps the design honest: **your eye does not send you
mail.** Build errors, lint findings, file-change hints — and the watch
supervisor's advisories about its own lifecycle, which have no
principal behind them either — are not communications from a party. They
are observations of the session's own workspace, owned by in-process
instruments. They keep their pull road — the drain — which is what
delivers them to the *running* turn, something the mailbox, by design,
never does.

## Reference-level explanation

### Vocabulary

`lib/session/queue.ml` — the entry gains a kind:

```ocaml
module Kind : sig
  type t = Message | Notification
end
(* Entry: { id : Id.t; input : Mentat_llm.Content.t list;
            origin : Origin.t option; kind : Kind.t } *)
```

A notification is ordinary content — no severity, no title, no key.
Those are drain-road (workspace `Notice`) vocabulary; the two words
name the two roads and are never mixed. `make` refuses empty input for
both kinds.

The kind sits on the entry, not the origin, because the same principal
legitimately sends both — the owner sends prompts and heads-ups; a
parent will send instructions and FYIs — and because admission judges
the principal while consumption obeys the entry: a kind-on-origin
spelling would fuse the two judgments `admits_mail` deliberately keeps
apart, and could not stay byte-identical.

`Turn_started` gains `folded : Queue.Id.t list` (default empty): the
notification entries this turn absorbed. `folded` is explicit rather
than rule-derived ("a turn consumes every notification enqueued before
it") so the fact carries its own consumption meaning: replay never
depends on a sweep rule a later binary might refine (a byte-capped or
selective fold), and the TUI mirror consumes ids instead of
re-implementing the rule beside the fold. Replay rejects a `folded` id
that names a message-kind entry, so the member can never become a side
door that consumes a message without minting its turn.

`State` gains one derived predicate, `pending_messages` — the
message-kind subset of the pending queue (see law N2).

### Admission and the witness

`admits_mail` keeps its one home and its two callers, and stays
byte-identical for message admission; the cap's counting rule is stated
in law N5. The admission ladder changes shape, not behavior:
`next_admission`'s `Queued` arm narrows to carry a **message witness**
— a value provable only from a message-kind entry — and
`start_queued_turn` takes the witness. A notification reaching the
turn-minting path is a type error, not a guard. Notifications are
invisible to the admission ladder; a queue holding only notifications
reads `Idle`.

### The fold

At the start of every turn whose input can carry appended content —
turns with `User` input: prompts, messages, wind-downs — turn
preparation sweeps all pending notification entries, frames each, and
appends them to the turn's input, recording their ids in `folded`.
Compaction (`Continue`) and plan-approval turns fold nothing; their
notifications wait. Queue order is arrival order — the one order the
journal already defines, so replay needs no other. The minting message
stays first and the notifications follow, whatever their arrival order:
the message is the turn's reason for being, and a notification that
must precede an instruction is a message mislabeled.

The fold frames every notification, the owner's included: a leading
line naming the sender and the kind — for the owner, "A notification
from your owner follows. It is information, not a new instruction." —
then the body as sender material, then a closing line ("End of
notification from X.") before the next frame opens. Two deliberate
divergences from message framing are stated here: an owner *message* is
verbatim content, but a verbatim fold would be indistinguishable from
the prompt it rides behind; and message frames are prefix-only, but
concatenated sender materials must not be able to forge each other's
openings, so folded bodies are closed as well as opened.

The fold deliberately does **not** ride the workspace statement batch
(`pending_notices`): a mail body is sender material and that block is
engine-authored and unfenced (N4; the rejected shape and its priced
wins are under Rationale).

### Consumption, failure, and queue edits

Consumption stays replay-derived — `Turn_started` removes its
origin-named message as today, plus every id in `folded`; the turn's
recorded input already carries the folded bytes, so replay never
re-derives framing. Two narrowings ride along:

- **The failure clear drops messages only.** Today `Turn_finished` with
  a `Failed` outcome empties the whole queue; under this RFC it drops
  message-kind entries only. A failed turn abandons the work queued
  behind it; it does not un-say what a sender said. Notifications
  survive and fold into whatever turn runs next. (Without this, one
  failed turn would silently destroy a "durable" CR announcement — and
  the delivery receipt outlives the entry, so it could never be
  re-sent.)
- **Queue edits are message edits.** `Replaced` replaces the
  message-kind entries and carries every pending notification through
  untouched (the driver re-appends them; the wire's `Replace_queued`
  still speaks only prompts). `Cleared` stays kind-blind — the owner's
  explicit clear is the one way to discard unread notifications, and
  its doc says so. The undo guard ("clear the queue before undoing")
  counts messages only. Esc-recovery recovers the newest **message**; a
  notification's body never enters the composer. (The default
  implementation of "skip" would otherwise lose notifications through
  `Replaced` — or worse, re-mint a notification body as an owner
  message with a turn of its own.)

A branch's reset clears unread notifications with the rest of the
inherited queue — stated, not accidental: the notification was
addressed to the original.

### Deliveries, live and dormant

A live delivery commits the enqueued fact mid-turn exactly as messages
do — immediately visible in the attached TUI's queue strip — and folds
at the next folding turn, never the current one. Same-turn freshness
remains the drain's job. A dormant target's notifications wait in its
journal; attach-at-boot admission folds them into the first turn.
Send-never-wakes is inherited whole, and strengthened (N2):
notifications never buy a wake, a spawn, or a linger.

### Encodings and compatibility

Decoder-first, additive-optional, old journals replay byte-identically:

- `Entry.jsont`: optional `"kind"` (`"message" | "notification"`),
  absent ⇒ message; the encoder omits it for messages, so every
  existing golden holds byte-identical. Unknown values reject loudly.
- `Fact.turn.started`: optional `"folded"` array, absent ⇒ empty,
  omitted when empty.
- `queue_updated` inherits the kind through the shared entry codec;
  `Queue_next` carries its own optional `"kind"` member (its codec is a
  flat record, not the entry codec) and `Broker.send` threads it
  through both arms. Absent ⇒ message everywhere. Zero new commands,
  zero new event kinds, envelope unchanged.
- Corpus: four new goldens (notification command, notification journal
  entry, folded turn-start, notification-preserving replace); no
  existing golden changes.

A journal written with either new member fails loudly in an older
binary — the strict-codec forward gap the mail vocabulary already
carries (unresolved question 1).

### Slice 1

The kind + witness + fold; the consumption narrowings and queue-edit
rules above; the CR sender in the review cone (owner origin — the
absence spelling — sent on compose success and on resolve, with ids
derived from the compose/resolve *event*, never the CR's position);
`mentat session send --notification`; the TUI queue-strip rendering,
Esc-recovery narrowing, and `folded` consumption in the mirror. Folded
notifications render inside their turn's input, so no free-standing
transcript placement is needed.

Doc repairs ride along: the workspace notice doc's aspirational
"code-review comments" clause (now a category error — CRs are
communications), the review screen's phantom `Task_mentat` claim, the
pre-0023 "notices are never journaled" passage, and the README/CHANGES
"delivered live" claim, which becomes true instead of deleted.

### The ledger

Adds ≈ 350 lines of product code (kind + codec ~35, admission filter
and witness ~25, fold + `folded` + closing fences ~95, judgment
narrowing across the `State.finished` home, the promptless-run virgin
arms, and the undo guard ~35, failure-clear kind split ~10, queue-edit
carry-through ~25, `Queue_next` member and threading ~15, TUI ~60, CR
sender ~35, CLI flag ~15), ~240 lines of tests, 4 goldens. Deletes ~10
lines of drifted docs and one product hole. This is a vocabulary
purchase, not a deletion, and says so: it is paid for by CR feedback
finally riding something, by the foreclosed alternative (notices-as-
mail: ≈ +500/−150 to move the same bytes one turn later), and by the
foreclosed future of bespoke channels — the engine never grows a third
intake.

## Laws

- **N1 — A notification never mints a turn.** Enforced by the message
  witness (Reference: Admission), not a runtime guard. *Prevents:*
  paying provider money for an FYI.
- **N2 — Send-never-runs.** Notifications are not unfinished work: the
  idle predicate, the supervisor's spawn judgment, the settlement
  judgment, and the failure-and-edit rules count unconsumed
  **messages** only. A child with only unread notifications is
  finished; they fold if it ever runs again. (One home carries most of
  this: `State.finished` narrows to messages, which the broker's spawn
  judgment, child settlement, serve idle-out, and status labels all
  consume. The promptless run's two virgin-session arms narrow with it,
  and the undo guard counts messages only.) *Prevents:* a serve process
  kept alive by an FYI; a supervisor spawning a process to not-start a
  turn; a settled child respawned to fold a heads-up. (This is the
  RFC's one amendment to RFC 0026's judgments.)
- **N3 — The sender keeps the baseline.** A sender sends only stated
  differences against what it last sent, with ids derived from the
  sending *event's* identity (for the CR sender: the compose/resolve
  act, never the CR's position — a position-derived id would swallow
  the next CR at the same ref forever, because the delivery receipt
  outlives consumption), so retries collapse to one effect. On
  `` `Refused_backlog `` it holds its observation, merges, and later
  sends one superseding notification — never spins, never drops. The
  mailbox dedups retries; it never dedups repetition; the cap is
  economics, not flow control. *Prevents:* floods; duplicate deliveries
  across crashes; lost content behind a full mailbox; retry storms.
- **N4 — A notification's body is sender material.** It is framed and
  fenced like message input, and every folded body is closed as well
  as opened; it never enters an engine-authored unfenced block. The
  fence is attribution, not containment — it names the sender and
  disowns the bytes; it does not prevent a body from containing
  frame-shaped text, which is why folded bodies carry closing edges.
  *Prevents:* a sender's bytes impersonating the engine's own
  statements — or a sibling notification's opening — to the model.
- **N5 — One cap, one judgment, kind-aware count.** One constant
  governs a sender: a notification is admitted against its total
  unconsumed entries (both kinds, 8), while a **message** is refused
  only on 8 unconsumed *messages*: a notification backlog
  can never refuse a message, because notifications free their slots
  only when the target runs, and under N2 nothing runs a target *for*
  them — a kind-blind count would let a sender's own FYIs permanently
  starve its instructions (the wake spawns nothing, the redrive refuses
  forever). Notification admission counts both kinds, so a verbose FYI
  sender still starves only itself. Kind-awareness admits no new
  attack: a hostile kin could already fill its 8 slots with messages,
  which cost the target strictly more. The owner exemption is
  unchanged. *Prevents:* a second judgment; the refusal-livelock above;
  relabeling pressure (relabeling an FYI as a message buys a turn,
  which is already the message price).
- **N6 — Communications ride mail; observations are pulled.** The test
  is the principal, and it is already a type: mail is content from a
  party the admission can judge — exactly the Origin vocabulary's three
  spellings (owner as absence, trigger, agent). Content with no
  principal — build state, lint findings, file-change hints, the watch
  supervisor's own lifecycle advisories — has no origin to judge and so
  cannot be mail; it stays on the drain, answerable to the drain
  contract instead of `admits_mail`. Loss cost follows the line rather
  than drawing it: a party's words are gone if dropped, while an
  instrument either re-states its truth (build, lint, fswatch) or
  speaks of a referent that dies with its own process (the supervisor's
  advisories). Residency never decides: the CR sender shares the
  serving process too and rides mail anyway — the owner is the party;
  the review cone is only their pen. *Prevents:* rebuilding either road
  inside the other — the false consolidation this campaign was asked to
  test.

## Drawbacks

- Net-add: four new concepts (`Kind`, `folded`, `pending_messages`, the
  message witness) with no offsetting deletion today — the ledger above
  says what pays for it, and Future possibilities names the deletion it
  arms.
- One more additive-optional member set on the strict codecs deepens
  the forward-compatibility gap that RFC 0026 q9 must eventually
  adjudicate.
- A notification can wait arbitrarily long (a forever-dormant session
  never folds). That is the design — informational content has no
  deadline — but senders must not assume timing (N3).
- The fold is the queue's first many-at-once consumption: one turn
  absorbs every pending notification, and the owner is cap-exempt, so
  forty CRs on an idle session fold into one turn's input. Accepted:
  they are forty real comments the model should see; per-entry byte
  caps bound each body, non-owner senders are bounded at 8, and flood
  control for the owner is the owner's own eyes, as everywhere in the
  product.

## Rationale and alternatives

- **Full migration — workspace notices as mail, the drain dies** (the
  mandate's own headline; the strongest alternative, so it is beaten on
  evidence, not preference). Every producer shares the engine's
  process, so mail transports nothing; same-turn delivery at claim
  settles dies — the agent finishes the turn blind to the build it just
  broke — or gets rebuilt inside the queue under a new name; coalescing
  becomes cap refusal for exactly the noisiest producers; and the
  ledger inverts (≈ +500/−150 for the same model-visible bytes, one
  boundary later). All three blind designs rejected it independently.
  *Yes, if* observation ever moves out of the serving process (a
  standing workspace observer): the notification kind built here is
  exactly what those producers would ride, by a transport swap, not a
  redesign.
- **Journal-side notice facts with mail as transport only.** A
  fact-push pipeline beside the queue: its own idempotence, its own
  backlog counting, a new wire command or a `Queue_next` that does not
  enqueue. The second mailbox RFC 0026 already adjudicated out.
- **Fold into the workspace statement batch** (the laws design's shape:
  notification payload = the session `Notice` type, folded into
  `pending_notices` by an atomic fact). What it genuinely wins is named
  so the rejection is priced: consumption at every admission pass (a
  live-but-unprompted target frees the sender's cap slots without a
  turn), a between-turns transcript receipt for the composer, and
  consume-plus-state in one atomic fact. None of it pays here: slice
  1's only sender is the exempt owner; cap timing for future senders is
  the Replaced arm's business (Non-goals); the queue strip's dim row is
  already the receipt; and `Turn_started` records input and `folded` in
  one fact — the same atomicity, one store earlier. The defects stand
  even with the batch fenced: sender bytes inside an engine-authored
  block (N4), and the queue is already the durable pending store, so
  the batch fold copies every notification into a second one and
  re-grows mail's sender framing inside the statement renderer.
- **A kind flag without the witness.** Leaves the illegal state
  representable — an "informational" entry reaching the minting path —
  and re-checks it at runtime in admission, recovery, and Esc-recover.
  The witness costs ~10 lines and deletes the class.
- **Zero vocabulary — CR ships as a drain producer** (the minimalist
  design). Honest and smaller (+250, no codec change), but its baseline
  is process memory: a CR composed and crashed before the next drain is
  never announced, and the road reaches only a served session.
  Durability at compose is the point of the forcing case; a
  communication's loss costs truth, not freshness. The minimalist
  design's own revisit trigger — "the first out-of-process sender" —
  is already visibly queued (mentatd advisories, R5 FYIs).
- **A separate cap (or none) for notifications.** Two pools, two
  judgments, and an incentive to relabel under pressure. N5 keeps one
  judgment with a kind-aware count instead.
- **Nudges as mail.** The whiff nudge is the fold's own reflex to the
  session's replayed facts — no sender, no distance, no transport. Mail
  would be attribution cosplay. Never, not "not yet".

## Non-goals

- The owner-line / conversation surface (parked): a folded notification
  renders wherever that design puts it; nothing here constrains it.
- Outbound mail consumed by mentatd (parked): unaffected; this RFC
  gives it a non-waking arrival kind for free.
- R5 grants / agent-origin notifications: the accept table stays
  kind-blind, so a granted contact sends either kind with zero new
  mechanism — but no agent sender ships here, and the send tool grows
  no kind argument until one does.
- Supersede/replace semantics for notifications (the queue's `Replaced`
  arm makes it cheap later; slice 1's only sender is the exempt owner —
  and the fold-at-admission wins priced under Rationale land here too).
- A hand-typed-CR rescan producer (the review cone covers the composed
  flow; *yes, if* hand-typed CRs prove dominant).

## Unresolved questions

1. **(rides RFC 0026 q9, before that adjudication)** The strict-codec
   forward gap now covers `"kind"` and `"folded"` too. One adjudication
   for the whole mail vocabulary; this RFC widens its scope and invents
   nothing.
2. **(during implementation)** Whether the TUI's queue strip orders
   notifications with messages strictly by arrival or groups unread
   notifications below pending prompts. Recommendation: arrival order —
   the strip mirrors the queue, and the queue is FIFO per sender.
3. **(during implementation)** The kind's type-level representation: a
   `kind` field plus an abstract witness in `next_admission`, or a
   two-arm payload sum with identical content types, where the match is
   the witness and one noun disappears at the cost of matching in every
   uniform-content path. Whichever reads as one screen; the wire member
   is identical either way.

## Future possibilities

(Per the anti-ratchet rule: nothing here is a reason to accept this or
a later RFC.) Agent-origin FYIs under R5 grants; mentatd → session
advisories (routine receipts, budget warnings); goal-state
notifications; the workspace observer leaving the serve process and its
producers switching to mail by transport swap, at which point the drain
road's port member becomes the deletion this RFC armed.
