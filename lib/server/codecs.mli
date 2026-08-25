(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The wire vocabulary the endpoint table names: the request/response object
    codecs each endpoint carries. Owner codecs are reused whole; a codec is
    built here only where an owner defers one. The two client-owned flow codecs
    live in {!Flow_codec}. *)

val ok_unit : unit Jsont.t
(** A [unit] result, crossing as the empty object [{}]. *)

val empty : unit Jsont.t
(** An empty request [{}] (endpoints whose driver field takes no argument). *)

val uri : Uri.t Jsont.t
(** A [Uri.t] as its string form; shared by the login-progress codecs. *)

(** {1:requests Request records} *)

type session_only = { session : Mentat_session.Id.t }

val session_only : session_only Jsont.t

type model_readiness = { refresh : bool }

val model_readiness : model_readiness Jsont.t
(** The model-readiness request. An absent [refresh] member decodes to
    [false] and a [false] value encodes as the empty object, so the default
    request crosses as [{}]. *)

type answer_unattended = {
  au_session : Mentat_session.Id.t;
  au_decision : Mentat_session.Decision.Id.t;
}

val answer_unattended : answer_unattended Jsont.t

type fork = {
  fork_session : Mentat_session.Id.t;
  fork_into : Mentat_session.Id.t;
}

val fork : fork Jsont.t

type rewind = {
  rw_session : Mentat_session.Id.t;
  rw_into : Mentat_session.Id.t;
  rw_anchor : Mentat_session.Anchor.t;
}

val rewind : rewind Jsont.t

type compact = {
  compact_session : Mentat_session.Id.t;
  compact_turn : Mentat_session.Turn.Id.t;
}

val compact : compact Jsont.t

type tail = { tail_session : Mentat_session.Id.t; tail_n : int option }

val tail : tail Jsont.t

type page = {
  page_session : Mentat_session.Id.t;
  page_n : int option;
  page_before : Mentat_protocol.Position.t option;
}

val page : page Jsont.t

type change_diff = {
  cd_session : Mentat_session.Id.t;
  cd_change : Mentat_mutation.Change.Id.t;
}

val change_diff : change_diff Jsont.t

type revert = {
  rv_session : Mentat_session.Id.t;
  rv_scope : Mentat_mutation.Revert.Scope.t;
}

val revert : revert Jsont.t

type save_api_key = { key_provider : Mentat_llm.Provider.t; key : string }

val save_api_key : save_api_key Jsont.t

type logout = { logout_provider : Mentat_llm.Provider.t; revoke : bool }

val logout : logout Jsont.t

type login = {
  login_provider : Mentat_llm.Provider.t;
  method_ : Mentat_provider.Auth.Login.Id.t;
}

val login : login Jsont.t

type set_model = {
  sm_session : Mentat_session.Id.t;
  sm_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
  sm_selector : Mentat_provider.Selector.t;
}

val set_model : set_model Jsont.t

type set_default_model = {
  sdm_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
  sdm_selector : Mentat_provider.Selector.t;
}

val set_default_model : set_default_model Jsont.t

type set_ui_theme = { sut_theme : string }

val set_ui_theme : set_ui_theme Jsont.t

type dune_control = { dc_op : [ `Restart | `Stop ] }

val dune_control : dune_control Jsont.t
(** The [workspace.dune_control] request: the user verb over the supervised
    build watch. *)

type set_permission_review = {
  spr_session : Mentat_session.Id.t;
  spr_review : Mentat_permission.Review_behavior.t;
}

val set_permission_review : set_permission_review Jsont.t

type create = { create_id : Mentat_session.Id.t; title : string option }

val create : create Jsont.t

type rename = { rename_session : Mentat_session.Id.t; rename_title : string }

val rename : rename Jsont.t
val listing : Mentat_session.Listing.t Jsont.t
val review_diff_path : Lpath.Rel.t Jsont.t

(** {1:responses Composed response codecs} *)

val sessions_result :
  (Mentat_session.Summary.t list * Mentat_diagnostic.t list) Jsont.t

val glance_result : (Textdiff.stats option * Mentat_workspace.Health.t) Jsont.t
