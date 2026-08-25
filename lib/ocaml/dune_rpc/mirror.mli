(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The host-side registry mirror for a supervised build watch.

    A watch spawned with a private [XDG_RUNTIME_DIR] registers itself where
    only its supervisor looks. This module writes the equivalent entry into
    the user's real Dune registry — the host process id and the watch's
    socket — so editor tooling discovers the watch exactly as it would one
    the user started, and removes the entry when the watch is gone. The
    caller owes removal on every exit path; a stale entry is otherwise
    ignored by readers only once its pid dies. *)

type t
(** The type for written mirror entries. A value names the registry file this
    mirror owns. *)

val write :
  env:(string -> string option) ->
  root:string ->
  pid:int ->
  socket:string ->
  (t, string) result
(** [write ~env ~root ~pid ~socket] writes one registry entry for the watch
    serving [socket] with host process id [pid] on the workspace rooted at
    [root], into the registry directory the ambient environment [env]
    designates (the same derivation Dune's own server uses), creating the
    directory as needed. [Error message] reports a failure to compute or
    write the entry; nothing is partially written that [remove] would not
    clean. *)

val path : t -> string
(** [path t] is the absolute path of the written registry file, for
    diagnostics. *)

val remove : t -> unit
(** [remove t] unlinks the mirror entry. Best-effort and idempotent: a file
    already gone is not an error. *)
