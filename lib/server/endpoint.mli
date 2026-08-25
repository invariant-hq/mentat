(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The endpoint-descriptor table: one value per non-streaming
    {!Mentat_client.Driver} field, shared by the [serve] dispatcher (by-name
    over {!table}) and the [connect] remote-driver (each row referenced at its
    concrete type). The feed and the login flow are the two streaming endpoints
    and are not rows here. *)

(** Per-variant idempotency. *)
type idempotency = By_domain_id | By_value | Requires_request_id

(* Session routing is not a descriptor field: every single-shot endpoint travels
   over POST /wire, and which calls route to a session's owner instance is
   decided at the composite driver by the [~session] label on the Driver field
   itself — the type structure, not an annotation, is the routing law. *)
type ('req, 'resp) t = {
  name : string;  (** The stable wire endpoint name. *)
  idempotency : idempotency;
  request : 'req Jsont.t;
  response : 'resp Jsont.t;
  invoke :
    Mentat_client.Driver.t -> 'req -> ('resp, Mentat_protocol.Error.t) result;
      (** The serve-side invocation: the driver field this row backs. *)
}

(** The existential backing {!table}'s by-name dispatch. *)
type any = Any : ('req, 'resp) t -> any

(** {1:session Session cone} *)

val submit : (Mentat_protocol.Command.t, unit) t
val answer_unattended : (Codecs.answer_unattended, unit) t
val possibly_mutating : (Codecs.session_only, bool) t
val fork : (Codecs.fork, unit) t
val rewind : (Codecs.rewind, unit) t
val compact : (Codecs.compact, Mentat_client.compaction_result) t

val pending_decision :
  (Codecs.session_only, Mentat_session.Decision.Requested.t option) t

val change_diff : (Codecs.change_diff, Textdiff.Hunk.t list) t
val tail : (Codecs.tail, Mentat_protocol.Transcript.Tail.t) t
val page : (Codecs.page, Mentat_protocol.Transcript.Page.t) t
val revert : (Codecs.revert, Mentat_mutation.Revert.Outcome.t) t
val export : (Codecs.session_only, string) t

(** {1:accounts Accounts cone} *)

val save_api_key : (Codecs.save_api_key, Mentat_provider.Account.t) t
val logout : (Codecs.logout, Mentat_provider.Account.Logout.t) t
val account_readiness : (unit, Mentat_provider.Account.Discovery.t list) t
val model_readiness :
  (Codecs.model_readiness, Mentat_provider.Model_readiness.t) t

(** {1:settings Settings cone} *)

val set_model : (Codecs.set_model, unit) t
val set_permission_review : (Codecs.set_permission_review, unit) t
val configuration : (unit, Mentat_config.Resolved.View.t) t
val set_default_model : (Codecs.set_default_model, unit) t
val set_ui_theme : (Codecs.set_ui_theme, unit) t

(** {1:lifecycle Lifecycle cone} *)

val create : (Codecs.create, unit) t
val rename : (Codecs.rename, unit) t
val archive : (Codecs.session_only, unit) t
val restore : (Codecs.session_only, unit) t
val delete : (Codecs.session_only, unit) t

val sessions :
  ( Mentat_session.Listing.t,
    Mentat_session.Summary.t list * Mentat_diagnostic.t list )
  t

val session : (Codecs.session_only, Mentat_session.Session_view.t) t

(** {1:review Review cone} *)

val review_apply : (Mentat_review.Command.t, unit) t
val review_state : (Mentat_review.Scope.t, Mentat_review.View.t) t
val review_diff : (Lpath.Rel.t, Mentat_review.File_diff.t option) t
val review_crs : (unit, Mentat_review.Cr.View.t list) t
val review_compose : (Mentat_review.Cr.Edit.t, unit) t

(** {1:workspace Workspace cone} *)

val glance : (unit, Textdiff.stats option * Mentat_workspace.Health.t) t

val dune_status : (unit, Mentat_workspace.Health.t) t
(** The watch status alone — [glance]'s dune half without the git read, for a
    frontend's transitional tick. *)

(** {1:lookup Lookup} *)

val table : any list
(** Every single-shot descriptor, in cone order. *)

val name_of : any -> string

val find : string -> any option
(** [find name] resolves a wire endpoint name to its descriptor, or [None]. *)

val submit_variant_requires_request_id : Mentat_protocol.Command.t -> bool
(** [submit_variant_requires_request_id command] is [true] for the two
    [session.submit] variants (Queue_next, Replace_queued) whose lost-ack retry
    duplicates a durable effect. It is the single named exception to the rule "a
    row needs a request-id iff its {!idempotency} is [Requires_request_id]",
    consulted by both the dispatcher and the remote driver so the classification
    cannot drift. *)
