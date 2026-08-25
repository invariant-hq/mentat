(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The filesystem watch lane: external-change notices and the claim-window
    observation intake.

    One polling {!Fswatch} watcher over the workspace root, pulled — never
    pushed. Every baseline advance happens on the engine's driver fiber, at
    exactly three points: {!claim_opened} advances as a tool claim's attribution
    window opens, so changes since the previous advance fall outside every
    window and queue as external changes; {!claim_window} advances as the window
    closes, and its diff is the window's observationally attributed paths —
    handed to {!Mentat_workspace_io.Claim_scope.observe}, never noticed;
    {!drain} advances and returns the queued external changes as one
    {!Mentat_workspace.Notice.t}. The watcher's single-consumer-fiber contract
    holds by construction, and no batch races a window: a change is external or
    window-observed according to the poll boundaries it falls between, decided
    synchronously on the driver fiber. A change that both an external writer and
    the window could claim is attributed to the window — observational
    attribution states what changed while the claim ran, not who caused it.

    Watching is best effort: a construction or scan failure degrades to one
    warning notice and permanently stops the lane; a session never fails because
    watching does. *)

type t
(** The type for one workspace's watch lane. *)

val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?ignore_prefix:Lpath.Rel.t ->
  root:Lpath.Abs.t ->
  unit ->
  t
(** [start ~sw ~clock ~root ()] is a watch lane over [root], its baseline the
    tree as it stands now. The watcher always uses the polling backend — pull
    boundaries are explicit, so native wakeups buy nothing. [ignore_prefix],
    when the snapshot store's data home lies inside the workspace, is that
    home's workspace-relative path, excluded from watching alongside version
    control metadata ([.git]), build and switch artifacts ([_build], [_opam]),
    and mentat's own workspace directory ([.mentat]). The lane stops when [sw]
    is released. *)

val claim_opened : t -> unit
(** [claim_opened t] advances the baseline as a tool claim's attribution window
    opens. Changes since the previous advance happened outside every window and
    queue as external changes for the next {!drain}. *)

val claim_window : t -> string list
(** [claim_window t] advances the baseline as the claim's attribution window
    closes and is the window's changed paths, absolute, for
    {!Mentat_workspace_io.Claim_scope.observe}. A change to the watched root
    directory itself is not a window path. *)

val drain : t -> Mentat_workspace.Notice.t list
(** [drain t] advances the baseline and is the queued external changes as at
    most one info notice, plus one warning notice the first drain after the lane
    degrades. The queue is cleared.

    The engine drains to prepare a turn, as each tool claim settles, and as
    delegated children deliver, so a workspace is walked once more per claim
    than the two window boundaries already cost. Every drain advances: skipping
    the walk after a window close would rest on that close always being followed
    by a drain, which an interrupted or store-failed settlement does not do. *)
