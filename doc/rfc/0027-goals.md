# RFC 0027 — Goals: continuation on the mail primitives

- Status: published (approved by the maintainer, 2026-08-29)
- Author: the maintainer, with Claude
- Requires: RFC 0026 (committed through R3; the goal rung lands after
  R4's eviction)
- Supersedes: nothing; re-admits the product surface RFC 0024 §11.4
  deleted, on different foundations

## Summary

A goal is recorded intent on a session: "keep working toward this,
within these bounds, until you declare it done." The old goal
machinery (~2,700 impl + ~2,400 test LOC) put the loop inside the
engine and was deleted with its reasons recorded (RFC 0024 §11.4,
§15.5). This RFC adds the surface back as one capability in a role
that already exists: the process driving a session — the steward
role the routine fire already plays for routine runs, and the TUI
and `mentat run` play for theirs — learns to read a recorded goal
intent and continue the session toward it (`/goal`). No new
component, no engine vocabulary, no wire commands, no second budget.
Model-driven self-continuation (self-mail) is out of scope
(§ future possibilities).

## Motivation

The attended use case the deletion conceded — "work through this
until done without me pressing enter each time" — is real, and its
substitutes (the queue, the todo board, plan mode) are partial. The
deletion ruling rejected an implementation, not the capability: the
old shape's sins were the loop living inside the model's driver (a
rumination surface at the wrong layer), a budget metering the wrong
denominator, and a first-class durable concept's full stack tax for
what is essentially "re-prompt on settle." The 0026 primitives —
session as agent, mail, the finished judgment, the journal fold,
recorded intent in metadata — carry the same semantics at a tenth of
the cost and make the old sins unconstructible.

## Guide

You are deep in a refactor and want mentat to finish it:

    /goal "get the test suite green" --max-turns 20 --budget 5.00

The session keeps working. Each time it goes idle — settled head,
empty queue, nothing of yours pending — the steward submits a
continuation. Each continuation turn ends with a `goal_status`
claim; when the claim says `done`, the loop stops and tells you.
You can chat with the session the whole time: your input always
runs first, and the goal resumes when the session is idle again.
`/goal stop` retires the intent. Esc interrupts a turn as always.

Close the terminal mid-goal and nothing is lost: the intent is in
the session document, an already-mailed continuation is durable
queue mail, and reopening the session shows the standing goal and
offers to resume. `mentat run --goal "…"` is the headless spelling;
`mentat run --resume` on a goal session re-arms the loop without
asking, since invoking it is the ask.

## Reference

**The steward.** Not a new component: the loop-holder is the process
already driving the session — the TUI's settle handling, `mentat
run`'s drive loop — never the engine. After R4 it is the same
create + send + supervise + read-the-journal shape as the routine
fire; the fire is the same role for routine runs. The goal feature
is one added decision inside that existing role:

    on finished (settled head AND empty queue):
      read the head turn's goal_status claim from the journal;
      done, bound reached, or budget spent → stop, notify;
      otherwise → submit the continuation; repeat.

**The intent** is one optional metadata member beside `Run_policy`:
objective, turn bound, budget. Written by owner verbs only (`/goal`,
`/goal stop`); mutually exclusive with `delegated_from` (a delegation
edge owns its child's contract) and with `triggered_from` in this
slice (a routine run already has a steward — the fire).

**Progress** is journal truth. The continuation prompt instructs the
model to end with a structured `goal_status` claim
(`{status: done | continuing, note?}`); the steward reads it with the
same head-claim projection the routine fold uses. An absent claim
means continuing — stopping requires the explicit declaration, the
bound, the budget, or the owner. Done-ness is derived, never written
back into metadata: no second record can disagree with the journal.

**The budget** is the journal's cost fold, read at each continuation
decision — the session's true total spend, the same fold that stamps
routine receipts.

**Durability.** The intent survives in the document. A mailed
continuation survives as queue mail; attach-runs-admission resumes it
with no goal machinery involved. The standing loop is process-bound,
exactly as the old goals' loop was; on resume the TUI offers
(`/goal resume` from a notice), headless `--resume` re-arms.

## Laws

- **L-G1 — The loop lives outside the context window it drives.**
  The engine never learns the word "goal." *Prevents:* the rejected
  in-engine self-prompting loop (RFC 0024 §15.5) returning by the
  back door.
- **L-G2 — Owner writes intent; model writes progress; the steward
  writes nothing.** Intent is metadata via owner verbs; progress is
  journal facts; the steward reads both and changes only its own
  conduct. *Prevents:* persisted derived state, and the model
  mutating its own leash.
- **L-G3 — Continuation fires on finished, never on settled.** User
  input preempts the loop by construction. *Prevents:* the goal
  stomping an interactive exchange.
- **L-G4 — Absent claim means continue.** Opt-out semantics: ending
  the goal takes the explicit declaration, the bound, the budget, or
  the owner — never the model forgetting. Landed adjudication: this
  law governs the model's declarations, not machinery — a FAILED
  head turn stops the loop loudly instead of silently burning the
  bound. *Prevents:* silent early stop being mistaken for
  completion.
- **L-G5 — The budget meters the journal's whole cost fold.**
  *Prevents:* the old mis-denominated budget (a first-turn completion
  fenced by nothing).
- **L-G6 — Every continuation is a framed, receipted turn.**
  Amended at implementation (2026-08-29): a claim exists only where
  the turn's contract seals the goal-status schema, and queue
  entries carry no per-turn contract — so continuations ride the
  owner's ordinary submission road, sealed through the existing
  generic output-schema channel; the engine stays goal-blind and
  the delivery spelling changed, never the law's point. *Prevents:*
  invisible engine reflexes; the transcript shows who continued the
  work and why.

## Drawbacks

The judge-side risk survives any opt-out design: a model declaring
"continuing" forever. It is bounded by supervisor-side facts (turns,
budget, wall clock where supervised, the owner elsewhere), not
solved. The steward is one more role name to teach — mitigated by it
being the routine fire's existing role, named once.

## Rationale and alternatives

- **Engine-hosted loop** (the old shape): rejected; §11.4/§15.5
  reasons stand unchanged — this RFC exists because the primitives
  now satisfy them.
- **A standing (recurring) queue entry** — admission re-arms it after
  each settle: rejected. It puts policy in the mailbox; the queue's
  referent is "messages the model has not seen," and a standing entry
  is not a message. The intent belongs in metadata with the other
  recorded contracts.
- **Goal as a routine**: rejected for this surface. Routines mint
  fresh runs per event and need mentatd; a goal continues one session
  and must work in mentat alone. The third row — progress while no
  mentat process runs — was never something old goals gave either;
  it remains routine territory.
- **A `goal_done` tool** (update_goal redux): rejected; the
  structured-output claim is already a validated terminating
  declaration with an existing projection, and one vocabulary beats
  two.

## Non-goals

No `update_goal` tool, no goal TUI screen, no wire commands, no
turn-origin arm, no goal-specific budget vocabulary. No model-driven
self-continuation: a session cannot mail itself in this RFC — the
model's only lever on the loop is the `goal_status` declaration. No
goals on delegated or trigger-born sessions in this slice. No
progress while no process runs (that is residency — mentatd's by
definition).

## Unresolved questions

**Before implementation:**
1. The role's name. This document says "steward"; "conductor" and
   "pilot" were considered. "Supervisor" and "driver" are taken.

**During implementation:**
2. The `goal_status` schema's exact members and whether the claim is
   required on every continuation turn or only when declaring done
   (L-G4 makes either safe).
3. Whether `/goal` on a session with a non-empty queue starts
   immediately (the mail waits its turn) or after the queue drains.
   Recommendation: it just records intent; the loop's first decision
   happens at the next finished — no special case.

## Future possibilities

*The anti-ratchet rule: nothing here is a reason to accept this RFC,
nor a later one.* Self-mail — the model continuing its own session
via a `self` send handle — would be one `admits_mail` arm, but it
needs its own bounding ruling first (the backlog cap does not bound
a consume-one-send-one loop; the bound must come from a supervisor's
clock or an attending owner). A goal on a trigger-born session (the
fire delegating its steward role); goal progress in the side pane
via the todo board; a routine arm that stewards a standing session
(RFC 0024 §15.1's named return).

## The ledger

Builds: one metadata member with codecs and exclusivity checks
(~60), the continue-or-stop decision in the existing steward
processes (~150–250), the slash command and `--goal`/`--resume` arms
(~80), tests (~300). No engine, wire, or store changes. Deletes: nothing (the old machinery is already gone);
prevents its 5,100-LOC shape from returning. Lands after R4, so the
loop is born onto the watch-based steward shape rather than ported
to it.
