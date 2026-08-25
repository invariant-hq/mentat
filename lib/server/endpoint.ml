(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* One endpoint-descriptor value per non-streaming [Driver] field. The table is
   the single pivot the [serve] dispatcher and the [connect]
   remote-driver share: [serve] decodes a request, resolves the row, calls
   [invoke], and encodes the result; [connect] encodes a request against the same
   row, POSTs to [name], and decodes the response. One description, two
   derivations, so the two cannot drift.

   The feed ([Session.follow]) and the login flow ([Accounts.login]) are the two
   streaming endpoints; they carry no single request/response pair, so they are
   not rows here — they are served over their own SSE streams. *)

(* Per-variant idempotency. [By_domain_id]: a client-minted id in
   the payload already makes admission find-or-create. [By_value]: re-applying
   converges with no duplicate effect (a lost-ack retry may surface a state error
   rather than the original [Ok], but the effect occurred exactly once).
   [Requires_request_id]: a lost-ack retry produces a durable duplicate or
   divergence, so the envelope's request-id is the only backstop. *)
type idempotency = By_domain_id | By_value | Requires_request_id

type ('req, 'resp) t = {
  name : string;
  idempotency : idempotency;
  request : 'req Jsont.t;
  response : 'resp Jsont.t;
  invoke :
    Mentat_client.Driver.t -> 'req -> ('resp, Mentat_protocol.Error.t) result;
}

(* The existential that lets one heterogeneous list back the [serve] dispatcher's
   by-name lookup. [connect] never needs it: it references each row at its
   concrete type. *)
type any = Any : ('req, 'resp) t -> any

(* Session cone. *)

let submit : (Mentat_protocol.Command.t, unit) t =
  {
    name = "session.submit";
    (* The endpoint carries all ten command variants; the per-variant class is
       resolved by the dispatcher off the decoded command. The
       row records the broadest safe default; only Queue_next/Replace_queued
       escalate to Requires_request_id, keyed on the variant. *)
    idempotency = By_value;
    request = Mentat_protocol.Command.jsont;
    response = Codecs.ok_unit;
    invoke =
      (fun d command ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.submit
          command);
  }

let answer_unattended : (Codecs.answer_unattended, unit) t =
  {
    name = "session.answer_unattended";
    idempotency = By_value;
    request = Codecs.answer_unattended;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.au_session; au_decision } ->
        d.Mentat_client.Driver.session
          .Mentat_client.Driver.Session.answer_unattended ~session:au_session
          ~decision:au_decision);
  }

let possibly_mutating : (Codecs.session_only, bool) t =
  {
    name = "session.possibly_mutating";
    idempotency = By_value;
    request = Codecs.session_only;
    response = Jsont.bool;
    invoke =
      (fun d { Codecs.session } ->
        Ok
          (d.Mentat_client.Driver.session
             .Mentat_client.Driver.Session.possibly_mutating ~session));
  }

let fork : (Codecs.fork, unit) t =
  {
    name = "session.fork";
    idempotency = By_domain_id;
    request = Codecs.fork;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.fork_session; fork_into } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.fork
          ~session:fork_session ~into:fork_into);
  }

let rewind : (Codecs.rewind, unit) t =
  {
    name = "session.rewind";
    idempotency = By_domain_id;
    request = Codecs.rewind;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.rw_session; rw_into; rw_anchor } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.rewind
          ~session:rw_session ~into:rw_into ~anchor:rw_anchor);
  }

let compact : (Codecs.compact, Mentat_client.compaction_result) t =
  {
    name = "session.compact";
    (* [compact] takes a client-minted compaction turn-id
       (mirroring [Prompt]), so a retry find-or-creates the same compaction fact —
       By_domain_id, off the request-id surface. *)
    idempotency = By_domain_id;
    request = Codecs.compact;
    response = Flow_codec.compaction_result;
    invoke =
      (fun d { Codecs.compact_session; compact_turn } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.compact
          ~session:compact_session ~turn:compact_turn);
  }

let pending_decision :
    (Codecs.session_only, Mentat_session.Decision.Requested.t option) t =
  {
    name = "session.pending_decision";
    idempotency = By_value;
    request = Codecs.session_only;
    response = Jsont.option Mentat_session.Decision.Requested.jsont;
    invoke =
      (fun d { Codecs.session } ->
        d.Mentat_client.Driver.session
          .Mentat_client.Driver.Session.pending_decision session);
  }

let change_diff : (Codecs.change_diff, Textdiff.Hunk.t list) t =
  {
    name = "session.change_diff";
    idempotency = By_value;
    request = Codecs.change_diff;
    response = Jsont.list Textdiff.Hunk.jsont;
    invoke =
      (fun d { Codecs.cd_session; cd_change } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.change_diff
          ~session:cd_session ~change:cd_change);
  }

let tail : (Codecs.tail, Mentat_protocol.Transcript.Tail.t) t =
  {
    name = "session.tail";
    idempotency = By_value;
    request = Codecs.tail;
    response = Mentat_protocol.Transcript.Tail.jsont;
    invoke =
      (fun d { Codecs.tail_session; tail_n } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.tail
          ?n:tail_n tail_session);
  }

let page : (Codecs.page, Mentat_protocol.Transcript.Page.t) t =
  {
    name = "session.page";
    idempotency = By_value;
    request = Codecs.page;
    response = Mentat_protocol.Transcript.Page.jsont;
    invoke =
      (fun d { Codecs.page_session; page_n; page_before } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.page
          ?n:page_n page_session ~before:page_before);
  }

let revert : (Codecs.revert, Mentat_mutation.Revert.Outcome.t) t =
  {
    name = "session.revert";
    (* A worktree-mutating, non-id-keyed operation — a
       lost-ack retry would mint a second Revert_started/Settled fact pair and
       re-run restore IO — so the envelope's request-id is the only backstop.
       This is [review_compose]'s class. *)
    idempotency = Requires_request_id;
    request = Codecs.revert;
    response = Mentat_mutation.Revert.Outcome.jsont;
    invoke =
      (fun d { Codecs.rv_session; rv_scope } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.revert
          ~session:rv_session ~scope:rv_scope);
  }

let export : (Codecs.session_only, string) t =
  {
    name = "session.export";
    (* A read: re-issuing streams the same bundle, no duplicate
       effect. The engine size-guards the buffered value before it crosses. *)
    idempotency = By_value;
    request = Codecs.session_only;
    response = Jsont.string;
    invoke =
      (fun d { Codecs.session } ->
        d.Mentat_client.Driver.session.Mentat_client.Driver.Session.export
          ~session);
  }

(* Accounts cone. *)

let save_api_key : (Codecs.save_api_key, Mentat_provider.Account.t) t =
  {
    name = "accounts.save_api_key";
    idempotency = By_value;
    request = Codecs.save_api_key;
    response = Mentat_provider.Account.jsont;
    invoke =
      (fun d { Codecs.key_provider; key } ->
        d.Mentat_client.Driver.accounts
          .Mentat_client.Driver.Accounts.save_api_key ~provider:key_provider
          ~key);
  }

let logout : (Codecs.logout, Mentat_provider.Account.Logout.t) t =
  {
    name = "accounts.logout";
    idempotency = By_value;
    request = Codecs.logout;
    response = Mentat_provider.Account.Logout.jsont;
    invoke =
      (fun d { Codecs.logout_provider; revoke } ->
        d.Mentat_client.Driver.accounts.Mentat_client.Driver.Accounts.logout
          ~revoke logout_provider);
  }

let account_readiness : (unit, Mentat_provider.Account.Discovery.t list) t =
  {
    name = "accounts.account_readiness";
    idempotency = By_value;
    request = Codecs.empty;
    response = Jsont.list Mentat_provider.Account.Discovery.jsont;
    invoke =
      (fun d () ->
        d.Mentat_client.Driver.accounts
          .Mentat_client.Driver.Accounts.account_readiness ());
  }

let model_readiness : (Codecs.model_readiness, Mentat_provider.Model_readiness.t) t
    =
  {
    name = "accounts.model_readiness";
    idempotency = By_value;
    request = Codecs.model_readiness;
    response = Mentat_provider.Model_readiness.jsont;
    invoke =
      (fun d { Codecs.refresh } ->
        d.Mentat_client.Driver.accounts
          .Mentat_client.Driver.Accounts.model_readiness ~refresh ());
  }

(* Settings cone. *)

let set_model : (Codecs.set_model, unit) t =
  {
    name = "settings.set_model";
    idempotency = By_value;
    request = Codecs.set_model;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.sm_session; sm_effort; sm_selector } ->
        d.Mentat_client.Driver.settings.Mentat_client.Driver.Settings.set_model
          ~session:sm_session ?reasoning_effort:sm_effort sm_selector);
  }

let set_permission_review : (Codecs.set_permission_review, unit) t =
  {
    name = "settings.set_permission_review";
    idempotency = By_value;
    request = Codecs.set_permission_review;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.spr_session; spr_review } ->
        d.Mentat_client.Driver.settings
          .Mentat_client.Driver.Settings.set_permission_review
          ~session:spr_session spr_review);
  }

let configuration : (unit, Mentat_config.Resolved.View.t) t =
  {
    name = "settings.configuration";
    idempotency = By_value;
    request = Codecs.empty;
    response = Mentat_config.Resolved.View.jsont;
    invoke =
      (fun d () ->
        d.Mentat_client.Driver.settings
          .Mentat_client.Driver.Settings.configuration ());
  }

let set_default_model : (Codecs.set_default_model, unit) t =
  {
    name = "settings.set_default_model";
    (* Re-applying converges: the same selector writes the same
       durable default, last-writer-wins on the atomic config rename. *)
    idempotency = By_value;
    request = Codecs.set_default_model;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.sdm_effort; sdm_selector } ->
        d.Mentat_client.Driver.settings
          .Mentat_client.Driver.Settings.set_default_model
          ?reasoning_effort:sdm_effort sdm_selector);
  }

let set_ui_theme : (Codecs.set_ui_theme, unit) t =
  {
    name = "settings.set_ui_theme";
    (* Re-applying converges: the same name writes the same durable theme,
       last-writer-wins on the atomic config rename. *)
    idempotency = By_value;
    request = Codecs.set_ui_theme;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.sut_theme } ->
        d.Mentat_client.Driver.settings
          .Mentat_client.Driver.Settings.set_ui_theme ~theme:sut_theme);
  }

(* Lifecycle cone. *)

let create : (Codecs.create, unit) t =
  {
    name = "lifecycle.create";
    idempotency = By_domain_id;
    request = Codecs.create;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.create_id; title } ->
        d.Mentat_client.Driver.lifecycle.Mentat_client.Driver.Lifecycle.create
          ~id:create_id ~title);
  }

let rename : (Codecs.rename, unit) t =
  {
    name = "lifecycle.rename";
    idempotency = By_value;
    request = Codecs.rename;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.rename_session; rename_title } ->
        d.Mentat_client.Driver.lifecycle.Mentat_client.Driver.Lifecycle.rename
          ~session:rename_session ~title:rename_title);
  }

let archive : (Codecs.session_only, unit) t =
  {
    name = "lifecycle.archive";
    idempotency = By_value;
    request = Codecs.session_only;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.session } ->
        d.Mentat_client.Driver.lifecycle.Mentat_client.Driver.Lifecycle.archive
          ~session);
  }

let restore : (Codecs.session_only, unit) t =
  {
    name = "lifecycle.restore";
    idempotency = By_value;
    request = Codecs.session_only;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.session } ->
        d.Mentat_client.Driver.lifecycle.Mentat_client.Driver.Lifecycle.restore
          ~session);
  }

let delete : (Codecs.session_only, unit) t =
  {
    name = "lifecycle.delete";
    idempotency = By_value;
    request = Codecs.session_only;
    response = Codecs.ok_unit;
    invoke =
      (fun d { Codecs.session } ->
        d.Mentat_client.Driver.lifecycle.Mentat_client.Driver.Lifecycle.delete
          ~session);
  }

let sessions :
    ( Mentat_session.Listing.t,
      Mentat_session.Summary.t list * Mentat_diagnostic.t list )
    t =
  {
    name = "lifecycle.sessions";
    idempotency = By_value;
    request = Codecs.listing;
    response = Codecs.sessions_result;
    invoke =
      (fun d listing ->
        d.Mentat_client.Driver.lifecycle.Mentat_client.Driver.Lifecycle.sessions
          ~listing);
  }

let session : (Codecs.session_only, Mentat_session.Session_view.t) t =
  {
    name = "lifecycle.session";
    idempotency = By_value;
    request = Codecs.session_only;
    response = Mentat_session.Session_view.jsont;
    invoke =
      (fun d { Codecs.session } ->
        d.Mentat_client.Driver.lifecycle.Mentat_client.Driver.Lifecycle.session
          session);
  }

(* Review cone. *)

let review_apply : (Mentat_review.Command.t, unit) t =
  {
    name = "review.apply";
    idempotency = By_value;
    request = Mentat_review.Command.jsont;
    response = Codecs.ok_unit;
    invoke =
      (fun d command ->
        d.Mentat_client.Driver.review.Mentat_client.Driver.Review.apply command);
  }

let review_state : (Mentat_review.Scope.t, Mentat_review.View.t) t =
  {
    name = "review.state";
    idempotency = By_value;
    request = Mentat_review.Scope.jsont;
    response = Mentat_review.View.jsont;
    invoke =
      (fun d scope ->
        d.Mentat_client.Driver.review.Mentat_client.Driver.Review.state ~scope);
  }

let review_diff : (Lpath.Rel.t, Mentat_review.File_diff.t option) t =
  {
    name = "review.diff";
    idempotency = By_value;
    request = Codecs.review_diff_path;
    response = Jsont.option Mentat_review.File_diff.jsont;
    invoke =
      (fun d path ->
        d.Mentat_client.Driver.review.Mentat_client.Driver.Review.diff ~path);
  }

let review_crs : (unit, Mentat_review.Cr.View.t list) t =
  {
    name = "review.crs";
    idempotency = By_value;
    request = Codecs.empty;
    response = Jsont.list Mentat_review.Cr.View.jsont;
    invoke =
      (fun d () ->
        d.Mentat_client.Driver.review.Mentat_client.Driver.Review.crs ());
  }

let review_compose : (Mentat_review.Cr.Edit.t, unit) t =
  {
    name = "review.compose";
    idempotency = Requires_request_id;
    request = Mentat_review.Cr.Edit.jsont;
    response = Codecs.ok_unit;
    invoke =
      (fun d edit ->
        d.Mentat_client.Driver.review.Mentat_client.Driver.Review.compose edit);
  }

(* Workspace cone. *)

let glance : (unit, Textdiff.stats option * Mentat_workspace.Health.t) t =
  {
    name = "workspace.glance";
    idempotency = By_value;
    request = Codecs.empty;
    response = Codecs.glance_result;
    invoke =
      (fun d () ->
        d.Mentat_client.Driver.workspace.Mentat_client.Driver.Workspace.glance
          ());
  }

let dune_status : (unit, Mentat_workspace.Health.t) t =
  {
    name = "workspace.dune";
    idempotency = By_value;
    request = Codecs.empty;
    response = Mentat_workspace.Health.jsont;
    invoke =
      (fun d () ->
        d.Mentat_client.Driver.workspace.Mentat_client.Driver.Workspace.dune
          ());
  }

let dune_control : (Codecs.dune_control, Mentat_workspace.Health.t) t =
  {
    name = "workspace.dune_control";
    idempotency = By_value;
    request = Codecs.dune_control;
    response = Mentat_workspace.Health.jsont;
    invoke =
      (fun d { Codecs.dc_op } ->
        d.Mentat_client.Driver.workspace
          .Mentat_client.Driver.Workspace.dune_control ~op:dc_op);
  }

(* The whole single-shot table, packed for the dispatcher's by-name lookup. *)

let table : any list =
  [
    Any submit;
    Any answer_unattended;
    Any possibly_mutating;
    Any fork;
    Any rewind;
    Any compact;
    Any pending_decision;
    Any change_diff;
    Any tail;
    Any page;
    Any revert;
    Any export;
    Any save_api_key;
    Any logout;
    Any account_readiness;
    Any model_readiness;
    Any set_model;
    Any set_permission_review;
    Any configuration;
    Any set_default_model;
    Any set_ui_theme;
    Any create;
    Any rename;
    Any archive;
    Any restore;
    Any delete;
    Any sessions;
    Any session;
    Any review_apply;
    Any review_state;
    Any review_diff;
    Any review_crs;
    Any review_compose;
    Any glance;
    Any dune_status;
    Any dune_control;
  ]

let name_of (Any d) = d.name
let find name = List.find_opt (fun any -> String.equal (name_of any) name) table

(* The one named exception to "idempotency is the descriptor's [idempotency]
   field": [session.submit] multiplexes ten command variants whose classes
   differ, so its row records the broad By_value default and this
   predicate escalates exactly Queue_next/Replace_queued to a request-id backstop.
   Both the dispatcher and the remote driver consult this single function, so the
   per-variant rule cannot drift between them. *)
let submit_variant_requires_request_id = function
  | Mentat_protocol.Command.Queue_next _
  | Mentat_protocol.Command.Replace_queued _ ->
      true
  | _ -> false
