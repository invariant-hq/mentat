(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The build-change law: what a settled reading says that the model has not
    heard.

    The law is a total, pure, clock-free function over the previous stated
    finding sets and a fresh reading. Per lane — build and lint,
    independently — it decides silence or exactly one change:

    - the same key set as last stated, in any order and at any positions, is
      silence — count-only shifts, moved lines, and duplicate reports say
      nothing;
    - a different non-empty key set is {!Failing}, naming what is new and how
      many resolved;
    - an empty set after a non-empty one is {!Recovered} — but only when the
      reading confirms the emptiness (see {!Reading.lane}); an unconfirmed
      empty lane is treated as no reading at all;
    - a lane with no reading leaves its baseline untouched: lost visibility
      never moves it, so an outage can neither fabricate a recovery nor
      forget a failure.

    {!step} threads a {!State.t} baseline so a producer drained many times per
    turn repeats nothing, and {!notice} renders a change as the model-visible
    {!Mentat_workspace.Notice.t}. *)

(** One settled reading of the diagnostic set. *)
module Reading : sig
  type t
  (** The type for readings. *)

  val make : ?lint_live:bool -> ?empty_confirmed:bool -> Finding.t list -> t
  (** [make findings] is a reading over [findings], partitioned by
      {!Finding.lane} — laneness is the finding's own fact, so a reading
      cannot mis-shelve one. The lint lane exists iff [lint_live] (default
      [false]) or a lint finding is present: an absent lint runner reads
      lint-absent, never lint-clean, and an absent lane leaves its baseline
      untouched exactly as a missing reading does.

      [empty_confirmed] (default [true]) records one producer-level fact:
      whether the settle that emptied the store was witnessed. A lane reading
      empty and unconfirmed never states a recovery — the cost asymmetry is
      deliberate, since a false recovery tells the model to stop working on a
      broken build while a late one costs almost nothing. *)

  val verdict : t -> Mentat_workspace.Health.Verdict.t
  (** [verdict t] is the build lane's verdict:
      {!Mentat_workspace.Health.Verdict.Clean} when it holds no finding, else
      {!Mentat_workspace.Health.Verdict.Failing} counting distinct findings by
      severity. The lint lane never participates. *)

  val lint : t -> int option
  (** [lint t] is the lint lane's distinct finding count, or [None] when the
      lane is absent from the reading. *)
end

(** The stated baseline the law diffs against. *)
module State : sig
  type t
  (** The type for baselines: per lane, the finding set last stated to the
      model. *)

  val initial : t
  (** [initial] is the empty baseline — an unremarkable clean start, so the
      first clean reading says nothing and the first failing one states every
      finding as new. *)
end

type t =
  | Failing of {
      lane : Finding.Lane.t;
      current : Finding.t list;
      fresh : Finding.t list;
      resolved : int;
    }
      (** The lane's set changed and is non-empty: [current] is the whole set,
          [fresh] the findings whose keys were not stated before, [resolved]
          how many stated keys vanished. *)
  | Recovered of Finding.Lane.t
      (** The lane's set is confirmed empty after a non-empty baseline. *)
(** The type for changes. *)

val step : State.t -> Reading.t option -> t list * State.t
(** [step state reading] is the changes the model has not heard, in lane order
    build first, and the advanced baseline. [None] — no settled reading — is
    silence and leaves [state] untouched. [step] is idempotent: feeding the
    same reading twice states nothing the second time. *)

val notice : t -> Mentat_workspace.Notice.t
(** [notice change] is the model-visible rendering of [change]:

    - build [Failing] is an [Error] notice — [Warning] when the set holds no
      error, which happens only when a failed build printed warnings alone —
      titled ["Build failing (<n> errors[, <m> warnings]: <k> new[, <r>
      resolved])"], its body the fresh findings' {!Finding.body_line}s (at
      most 20, then an elision count) followed by ["<u> unchanged since the
      last notice"] when any stated finding survives;
    - lint [Failing] is the same shape titled ["<n> findings (…)"], severity
      [Error] iff any finding is;
    - build [Recovered] is the [Info] notice ["Build recovered"], lint
      [Recovered] the [Info] notice ["Lint clean"], both bodyless.

    Sources are ["dune"] and ["lint"]; keys ["dune.build"] and ["dune.lint"],
    one per lane, so a queued newer notice replaces an older one of its lane.
*)
