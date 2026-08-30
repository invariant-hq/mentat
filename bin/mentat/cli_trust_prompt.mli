(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Executable-private presentation for the workspace trust gate.

    This module owns only the prompt's semantic state and Mosaic presentation.
    The caller supplies the persistence decision, so trust-store IO and launch
    gating remain outside the UI. [Matrix_eio] hosts the app; Matrix owns
    terminal modes and decoded key and resize-event delivery, including
    [SIGWINCH]; Mosaic owns input routing, wrapping, layout, overflow, and
    scrolling. Maintainers must not duplicate those responsibilities with ANSI
    redraws, raw terminal or byte-level key handling, or row/column arithmetic.
*)

type choice =
  | Untrusted
  | Trusted
      (** A persistable choice made in the prompt. Exiting is represented by
          {!Exit_prompt}, because it must never reach trust persistence. *)

type 'a outcome =
  | Continue of 'a
  | Exit_prompt
      (** The outcome of the prompt. [Continue value] carries the launch
          decision produced by the executable's [decide] callback. *)

val run :
  ?notice:string ->
  ?home:Lpath.Abs.t ->
  stdenv:Eio_unix.Stdenv.base ->
  root:Lpath.Abs.t ->
  decide:(choice -> ('a, string) result) ->
  unit ->
  'a outcome
(** [run ~stdenv ~root ~decide ()] displays the trust prompt and blocks until
    the user saves a choice or exits. [stdenv] supplies the [Matrix_eio]
    terminal host. [root] is displayed relative to [home] when it lies below it,
    the same workspace spelling the rest of the interface uses; the value passed
    to [decide] is unaffected. If [notice] is present, the prompt initially
    displays it as a diagnostic. [decide choice] performs executable-owned
    persistence and produces the value returned in [Continue]. An [Error]
    replaces the visible diagnostic and permits a retry.

    [decide] runs synchronously in the caller's existing execution context. It
    should perform only the bounded local trust-store update. *)
