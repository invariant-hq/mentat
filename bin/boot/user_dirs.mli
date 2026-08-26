(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Executable-owned directory discovery — executable-private, with the
    libraries performing no path or home resolution of their own.

    The XDG ladder: an absolute [MENTAT_*_HOME] override wins, else
    [XDG_*_HOME/mentat], else [$HOME/…]. A relative override is a hard error — a
    resolved home must be absolute so every capability the composition root
    opens is unambiguous. Config home holds [config.json], [auth.json], and
    [trust.json]; data home is the session store root; state home holds logs and
    history. *)

type t
(** Resolved absolute directory roots. *)

val resolve : getenv:(string -> string option) -> (t, string) result
(** [resolve ~getenv] resolves the three roots from the process environment.
    [Error message] when a set override is relative or a fallback [$HOME] is
    unavailable. *)

val config_home : t -> string
(** [config_home t] is the absolute config directory. *)

val data_home : t -> string
(** [data_home t] is the absolute data directory — the session store root. *)

val state_home : t -> string
(** [state_home t] is the absolute state directory. *)

val config_file : t -> string
(** [config_file t] is [config_home / "config.json"]. *)

val auth_file : t -> string
(** [auth_file t] is [config_home / "auth.json"] — the credential store. *)

val trust_file : t -> string
(** [trust_file t] is [config_home / "trust.json"] — the workspace trust store.
*)

val daemon_dir : t -> string
(** [daemon_dir t] is [data_home / "daemon"] — the per-user daemon's private
    directory: it holds the discovery file [daemon.json], the claim lock
    [daemon.lock], and the spawned daemon's log [daemon.log]. Homed under the
    data home so a [MENTAT_DATA_HOME] override isolates a daemon per store. The
    socket does not live here — it lives under [/tmp] to fit [sun_path]. *)

val charters_dir : t -> string
(** [charters_dir t] is [config_home / "charters"] — the root under which each
    charter owns one directory. Homed under the config home because a charter
    is owner-written policy, never workspace or session state. *)

val charter_dir : t -> string -> string
(** [charter_dir t name] is [charters_dir / name] — the directory holding
    [name]'s [charter.json], prompt and schema files, [ingress.id], and
    [secrets/]. *)

val charter_state_dir : t -> string -> string
(** [charter_state_dir t name] is [state_home / "charters" / name] — the
    charter's durable record: its receipt log, its per-event-identity claim
    markers, and its run roots. Homed under the state home, apart from the
    config-home policy, so removing a charter's configuration can leave its
    audit trail in place. *)

val daemon_socket_dir : t -> string
(** [daemon_socket_dir t] is [/tmp/mentat-<uid>-<key>], the directory the
    per-user daemon binds its socket in — under [/tmp] so a deep checkout cannot
    overflow [sun_path], keyed on the data home so a [MENTAT_DATA_HOME] override
    isolates daemons.

    Two callers need it and neither can see the other: the daemon binds it, and
    the sandbox denies it. The denial is not optional. [/tmp] is granted
    writable, and the socket authorizes any local peer without a token, so a
    confined command able to reach it would be driving Mentat instead of being
    confined by it. *)

val child_socket_dir : t -> session:string -> string
(** [child_socket_dir t ~session] is the directory a per-session child server
    binds its socket in: [s/<leaf>] under {!daemon_socket_dir}, so the sandbox
    denial covering the daemon's socket tree covers every child endpoint with no
    further policy. [leaf] is [session] itself when it is a plain filename
    component (ASCII alphanumerics, [-], [_], [.]; no leading dot) of at most 40
    bytes — which keeps the whole [<dir>/mentat.sock] path more than 15 bytes
    under the tightest (macOS, 104-byte) [sun_path] cap for any uid up to seven
    digits — and a 16-hex keyed digest of [session] otherwise. Either way the
    endpoint is a pure function of the session id, so the binding child and a
    connecting broker derive the same path independently. *)
