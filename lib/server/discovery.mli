(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The daemon discovery file and its claim lock.

    A per-user daemon advertises itself through one small file so a client can
    find it, health/version-check it, and reuse it — or spawn a fresh one. This
    module owns the {b format and discipline} of that file (strict-decode JSON,
    the credential-store atomic-write discipline against symlink planting) and
    the {b claim lock} that serialises daemon starts; it owns no path policy and
    no process spawning — the daemon binary decides {e where} the directory
    lives and {e when} to spawn (the same lib-mechanics vs bin-paths split as
    [credential_store] vs [user_dirs]). It links [unix], [jsont], and [lpath] —
    never a store, engine, or provider transport. *)

type t = {
  socket : string;
      (** Absolute path of the unix socket the daemon listens on. *)
  pid : int;
      (** The daemon process id — diagnostic display and [--stop]'s target only;
          never a liveness probe (pid reuse lies). Liveness is the {!Claim}. *)
  protocol : int;  (** The handshake floor — {!Mentat_server}'s wire version. *)
  binary : string;
      (** The daemon's build version, for the attach mismatch gate. *)
  config_home : string;
      (** The daemon's resolved config home; an attach whose config home differs
          refuses (a daemon composing a different [auth.json]/config than the
          client expects is a confusion, not a convenience). *)
  started_at : int;  (** Unix milliseconds at daemon start; diagnostic. *)
  web_url : string option;
      (** The browser-frontend URL — with its single-use bootstrap token — when
          the daemon runs [--web]; [None] otherwise. Optional and additive (no
          file-format [v] bump): recorded so a browser-open path can find the
          URL without parsing daemon stdout. *)
  ingress : string option;
      (** The loopback address ([127.0.0.1:port]) the webhook ingress listener
          bound when the daemon was given an ingress port; [None] when no
          ingress listener runs. Optional and additive like [web_url]:
          recorded so status tooling and a dashboard can find the bound
          port — which may be ephemeral — without parsing daemon stdout. *)
}
(** The discovery record. The concrete type is exposed
    (private-modules-have-mlis law); a reader threads it whole. *)

val jsont : t Jsont.t
(** [jsont] maps the record to a JSON object with a required file-format version
    member ([v = 1]), strict-decoded: an unknown version or member is rejected
    so a reader never mis-reads a foreign or future file as one of its own. *)

val write : dir:Lpath.Abs.t -> t -> (unit, string) result
(** [write ~dir t] writes [t] as [dir]/[daemon.json] with the credential-store
    discipline: [dir] created (and required) mode 0700, an exclusive-create 0600
    temp file (a pid+stamp+counter name), then an atomic [rename] — so a reader
    can never observe a torn file, and a symlink planted at the target cannot
    redirect the write. [Error] carries a human-readable reason. *)

val read : dir:Lpath.Abs.t -> [ `Found of t | `Absent | `Foreign of string ]
(** [read ~dir] reads [dir]/[daemon.json]. [`Absent] when the file does not
    exist; [`Foreign reason] when it is present but undecodable or of an unknown
    file-format version — never clobbered by a reader, only reclaimed by a fresh
    daemon start; [`Found t] otherwise. *)

(** The daemon claim lock: an OS advisory lock ([lockf F_TLOCK], [O_CLOEXEC])
    held by the daemon for its whole life, plus an in-process claimed-set so a
    same-process contender is honestly excluded (the [run_lock] registry idiom).
    Kernel-released on owner death, so
    {e the lock, not the pid, is the liveness truth}. *)
module Claim : sig
  type guard
  (** A held claim; releasing it drops the lock. *)

  val try_acquire : dir:Lpath.Abs.t -> (guard, [ `Held | `Io of string ]) result
  (** [try_acquire ~dir] takes [dir]/[daemon.lock] non-blocking. [`Held] when
      another process (or this process) already holds it — the signal that
      collapses N racing daemon starts to one; [`Io reason] on a filesystem
      error. *)

  val release : guard -> unit
  (** [release guard] drops the lock and the in-process reservation. Idempotent.
      Owner death releases it regardless. *)
end

val clear : dir:Lpath.Abs.t -> pid:int -> unit
(** [clear ~dir ~pid] unlinks [dir]/[daemon.json] only if it still names [pid]
    (compare-and-unlink) — safe because no successor can claim until the owner's
    lock releases at exit. A no-op when the file is absent, foreign, or names
    another pid. *)
