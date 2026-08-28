(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The per-session endpoint's shared machinery.

    What every per-session endpoint is made of: the confined session cone
    that answers only for one session and its delegation subtree, the
    handshake binder for a single-workspace server, and the socket-directory
    discipline. The per-session child server ([mentat serve]) consumes
    these pieces directly and owns its own boot, idle watchdog, and exit. *)

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
    shared store. The two session-scoped settings writes ([set_model],
    [set_permission_review]) pass under the same membership guard — their
    overlays live in the driving process, which is exactly this one, so the
    frontend that opened the session reaches them here. Every other cone —
    accounts, the sessionless settings, lifecycle, review, workspace — is
    refused whole: a per-session endpoint exists to drive one session, not to
    reach the user's accounts, configuration, or session index. *)

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
    is refused. The offered environment is ignored — the serving agent keeps
    the environment it booted with. *)

val ensure_socket_parents : string -> unit
(** [ensure_socket_parents dir] creates [dir]'s parent directories [0700] —
    the per-session socket home is two levels below the socket base, and the
    server's listen hardens only its leaf. *)

val remove_socket : string -> unit
(** [remove_socket dir] removes the endpoint directory [dir] — the backstop
    for a teardown that could not run; a gone socket directory is the visible
    sign of a cleanly exited endpoint. *)
