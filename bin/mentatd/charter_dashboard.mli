(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The charters page — the needs-me-first dashboard on the daemon's web
    mount.

    One read-only, server-rendered page. What needs the owner renders
    first: runs that parked on a question or settled without a publishable
    outcome (the identity-scoped alerts the fire pipeline wrote), charters
    whose configuration no longer loads, receipt logs this build cannot
    read, live runs holding their fence past the wall clock, tripped
    budget fences, and settled runs whose publication is still owed. Below
    that sits the routine record, one row per loadable charter: state,
    digest, spend and rate against their fences, the last disposition and
    egress, and the webhook ingress address. Every value derives at
    request time from the roster, the receipt logs, and non-contending
    run-fence probes — nothing is cached and no projection is persisted,
    so the page can never disagree with the record it renders, and an
    owner's edit is in force at the next request. The page mutates
    nothing: installing, enabling, and removing charters stay with the
    CLI, and the page renders no controls.

    {!observe} is the effectful read; {!page} is the pure projection over
    its result, exercised directly by tests over hand-built
    observations. *)

(** What one request observed. *)
module Observed : sig
  type run = {
    pending : Mentat_charter.Receipt.Pending.t;
        (** A spawned disposition with no reaped line. *)
    fence : Mentat_charter.Record.fence;
        (** The run's fence, probed at request time. *)
  }
  (** The type for open runs, paired with the liveness probe the
      pending-run judgment reads. *)

  type charter = {
    loaded : Charter_store.Loaded.t;  (** The loaded policy closure. *)
    receipts : (Mentat_charter.Receipt.t list, Charter_store.Error.t) result;
        (** The charter's receipt log, or why it could not be read. *)
    runs : run list;
        (** The open runs; empty when the receipts are unreadable. *)
  }
  (** The type for observed loadable charters. *)

  type t =
    | Broken of { name : string; error : Charter_store.Error.t }
        (** A roster entry that failed to load, with the refusal. *)
    | Charter of charter  (** A loaded charter and its record. *)
  (** The type for per-charter observations. *)
end

val observe :
  dirs:User_dirs.t ->
  store:Mentat_store.t ->
  (Observed.t list, Charter_store.Error.t) result
(** [observe ~dirs ~store] reads the installed roster and, per loadable
    charter, its receipt log and one fence probe per open run — all fresh
    on every call, since the files are the registration and an owner's
    edit must be in force at the next request. The probes never contend: a
    held fence is observed, never acquired. The outer [Error] is an
    unreadable charters directory. *)

val page :
  now:float ->
  ingress:string option ->
  (Observed.t list, Charter_store.Error.t) result ->
  Mentat_web.Html.t
(** [page ~now ~ingress observed] is the complete dashboard document for
    [observed]. Attention items render first, bucketed in fixed order —
    parked, failed, broken charters, unreadable receipts, overdue runs,
    unprobeable fences, tripped fences, owed publications — with the
    roster's and the log's own order standing inside each bucket; the
    per-charter record follows. An empty roster, an empty attention list,
    and a roster read failure each render their own plain statement, never
    a blank. [now] anchors the fence windows and the wall-clock judgment;
    [ingress] is the bound webhook ingress address ([None] when no ingress
    listener is up), prefixed onto each webhook charter's ingress path. *)
