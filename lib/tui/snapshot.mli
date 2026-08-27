(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Launch fallback and last-started-turn facts rendered by the TUI.

    A snapshot is presentation-safe: its labels are valid, inert, single-line
    UTF-8; [version] and [model] are visibly nonblank; optional labels are
    visibly nonblank when present; and [context_window] is positive when
    present. Malformed UTF-8 and terminal controls in external labels are
    replaced with [U+FFFD], while tabs and line boundaries become spaces.

    The executable supplies the fallback facts at launch. The model line is the
    model the next turn will use: a replayed or live [Turn_started] fact records
    the exact sealed turn model, and a model selection — engine-confirmed for
    the active session, or staged for the session the first prompt will start —
    records the chosen selector, all through {!with_model}. The launch context
    window is retained only while it still describes that model. *)

type t
(** The type for one session's display snapshot. *)

val make :
  version:string ->
  model:string ->
  effort:string option ->
  cwd:Lpath.Abs.t ->
  home:Lpath.Abs.t option ->
  context_window:int option ->
  sandbox:string option ->
  trusted:bool ->
  t
(** [make ~version ~model ~effort ~cwd ~home ~context_window ~sandbox
     ~trusted] constructs the launch snapshot.

    External string labels are normalized as described for {!t}. A visibly blank
    [version] becomes ["[version unavailable]"], and a visibly blank [model]
    becomes ["[model unavailable]"]. Visibly blank [effort] and [sandbox] labels
    become [None]. A zero or negative [context_window] becomes [None]. *)

val version : t -> string
(** [version t] is the normalized build version shown in the banner. *)

val model : t -> string
(** [model t] is the normalized launch fallback or last-started main-model
    label. *)

val effort : t -> string option
(** [effort t] is the normalized effective reasoning effort of the launch
    fallback or last-started turn. *)

val cwd : t -> Lpath.Abs.t
(** [cwd t] is the absolute launch workspace. *)

val home : t -> Lpath.Abs.t option
(** [home t] is the launch-fixed home directory used to spell workspace paths as
    [~] or [~/rest], when available. *)

val context_window : t -> int option
(** [context_window t] is the positive context window associated with {!model},
    when known. *)

val sandbox : t -> string option
(** [sandbox t] is the normalized presentation label for the launch sandbox,
    when available. It carries no sandbox capability or posture. *)

val trusted : t -> bool
(** [trusted t] is whether the launch workspace was trusted. Launch-fixed:
    a trust decision recorded elsewhere takes effect at the next session.
    An untrusted workspace degrades the whole session — project config
    unread, project tooling off — so the surfaces render the state rather
    than letting its absences speak one row at a time. *)

val with_model :
  model:string -> effort:string option -> ?context_window:int -> t -> t
(** [with_model ~model ~effort ?context_window t] records the model line the
    next turn will use after normalizing both labels: the exact sealed model and
    effort of a newly started turn, the selector and effort of a next-turn
    selection the engine has confirmed, or a selection staged before any session
    exists for the first prompt to apply. It retains [context_window t] when the
    normalized [model] equals [model t]. Otherwise it adopts [context_window] —
    the incoming model's provider-owned window, which the caller resolves from
    the catalog — normalizing a non-positive or absent value to [None]. *)

val model_line : t -> string
(** [model_line t] is [model t] followed by one space and [effort t] when an
    effort is present, and [model t] otherwise. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff every snapshot fact in [a] and [b] is equal. *)
