(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Serving one session's derived socket beside its driver.

    The shared machinery of every per-session endpoint: the confined session
    cone that answers only for one session and its delegation subtree, the
    handshake binder for a single-workspace server, the socket-directory
    discipline, and — transitional, dying with the in-process drivers it
    exists for — {!mount}, the serve-mount bridge: a process hosting an
    in-process driver binds the driven session's derived socket and serves
    the confined cone while it drives, so another process's send reaches the
    session over the wire instead of spending its budget against the held
    fence. The per-session child server ([mentat serve-session]) consumes the
    shared pieces directly and owns its own boot, idle watchdog, and exit. *)

(** One cached, stamp-elided store of durable-head summaries, shared by every
    consumer of the subtree walk over one endpoint's lifetime so each journal
    decodes once per stamp. *)
module Heads : sig
  type t
  (** The type for the cache. *)

  val create : unit -> t
  (** [create ()] is an empty cache. *)

  val summary :
    store:Mentat_store.t ->
    t ->
    Mentat_session.Id.t ->
    (bool * Mentat_session.Id.t list) option
  (** [summary ~store t session] is one fence-free read of [session]'s
      durable head: whether it is settled with an empty queue, and its
      recorded delegation children. [None] when the stamp or the journal
      cannot be read — outstanding work is presumed. *)
end

val confined :
  store:Mentat_store.t ->
  cache:Heads.t ->
  served:Mentat_session.Id.t ->
  Mentat_client.Driver.t ->
  Mentat_client.Driver.t
(** [confined ~store ~cache ~served driver] is [driver] with the one-session
    confinement applied: the session cone answers only for [served] and its
    own delegation subtree — membership decided by journal truth through
    [cache] — and a foreign session id is refused, never resolved against the
    shared store. Every other cone — accounts, settings, lifecycle, review,
    workspace — is refused whole: a per-session endpoint exists to drive one
    session, not to reach the user's accounts, configuration, or session
    index. *)

val driver_for :
  root:string ->
  driver:Mentat_client.Driver.t ->
  active:int Atomic.t ->
  workspace:string option ->
  environment:(string * string) list option ->
  (Mentat_server.target, Mentat_protocol.Error.t) result
(** [driver_for ~root ~driver ~active] is the single-workspace handshake
    binder: a handshake naming exactly [root] binds [driver] and counts the
    connection in [active] until its close; any other — or absent — workspace
    is refused. The offered environment is ignored — the serving instance
    keeps the environment it booted with, exactly as a live daemon instance
    does. *)

val ensure_socket_parents : string -> unit
(** [ensure_socket_parents dir] creates [dir]'s parent directories [0700] —
    the per-session socket home is two levels below the socket base, and the
    server's listen hardens only its leaf. *)

val remove_socket : string -> unit
(** [remove_socket dir] removes the endpoint directory [dir] — the backstop
    for a teardown that could not run; a gone socket directory is the visible
    sign of a cleanly exited endpoint. *)

val mount :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  store:Mentat_store.t ->
  dirs:User_dirs.t ->
  driver:Mentat_client.Driver.t ->
  root:Lpath.Abs.t ->
  session:Mentat_session.Id.t ->
  (unit -> unit) option
(** [mount ~sw ~stdenv ~store ~dirs ~driver ~root ~session] is the
    transitional serve-mount bridge: it binds [session]'s derived socket
    ({!User_dirs.child_socket_dir}) and serves [driver]'s {!confined} cone on
    a fiber under [sw], returning the idempotent unmount that stops serving.
    The socket file is unlinked by the listener's teardown at switch close;
    an empty endpoint leaf directory may remain, which the broker's
    rediscovery sweep tolerates. The caller must hold the session's
    run fence under {!Mentat_broker.serve_mount_owner_label} for as long as
    the mount serves — the label is what routes a send's wire arm here. A
    bind that fails — a socket path over the [sun_path] budget, a colliding
    endpoint — is [None], logged as a warning and never fatal: the bridge is
    a reachability upgrade, not a condition of driving. *)
