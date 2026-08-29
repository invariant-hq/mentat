(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type compaction_result = Installed | Skipped

module Session = struct
  type t = {
    submit :
      Mentat_protocol.Command.t -> (unit, Mentat_protocol.Error.t) result;
    follow :
      Mentat_session.Id.t ->
      from:Feed.from ->
      (Feed.seam, Mentat_protocol.Error.t) result;
    answer_unattended :
      session:Mentat_session.Id.t ->
      decision:Mentat_session.Decision.Id.t ->
      (unit, Mentat_protocol.Error.t) result;
    possibly_mutating : session:Mentat_session.Id.t -> bool;
    faulted : session:Mentat_session.Id.t -> Mentat_diagnostic.t option;
    fork :
      session:Mentat_session.Id.t ->
      into:Mentat_session.Id.t ->
      (unit, Mentat_protocol.Error.t) result;
    rewind :
      session:Mentat_session.Id.t ->
      into:Mentat_session.Id.t ->
      anchor:Mentat_session.Anchor.t ->
      (unit, Mentat_protocol.Error.t) result;
    compact :
      session:Mentat_session.Id.t ->
      turn:Mentat_session.Turn.Id.t ->
      (compaction_result, Mentat_protocol.Error.t) result;
    pending_decision :
      Mentat_session.Id.t ->
      ( Mentat_session.Decision.Requested.t option,
        Mentat_protocol.Error.t )
      result;
    running_processes :
      Mentat_session.Id.t ->
      (Mentat_protocol.Process.View.t list, Mentat_protocol.Error.t) result;
    change_diff :
      session:Mentat_session.Id.t ->
      change:Mentat_mutation.Change.Id.t ->
      (Textdiff.Hunk.t list, Mentat_protocol.Error.t) result;
    tail :
      ?n:int ->
      Mentat_session.Id.t ->
      (Mentat_protocol.Transcript.Tail.t, Mentat_protocol.Error.t) result;
    page :
      ?n:int ->
      Mentat_session.Id.t ->
      before:Mentat_protocol.Position.t option ->
      (Mentat_protocol.Transcript.Page.t, Mentat_protocol.Error.t) result;
    revert :
      session:Mentat_session.Id.t ->
      scope:Mentat_mutation.Revert.Scope.t ->
      (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result;
    undo :
      session:Mentat_session.Id.t ->
      op:[ `Undo | `Redo | `Cancel ] ->
      (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result;
    export :
      session:Mentat_session.Id.t -> (string, Mentat_protocol.Error.t) result;
  }
end

module Accounts = struct
  type t = {
    login :
      provider:Mentat_llm.Provider.t ->
      method_:Mentat_provider.Auth.Login.Id.t ->
      (Login.steps, Mentat_protocol.Error.t) result;
    save_api_key :
      provider:Mentat_llm.Provider.t ->
      key:string ->
      (Mentat_provider.Account.t, Mentat_protocol.Error.t) result;
    logout :
      ?revoke:bool ->
      Mentat_llm.Provider.t ->
      (Mentat_provider.Account.Logout.t, Mentat_protocol.Error.t) result;
    account_readiness :
      unit ->
      (Mentat_provider.Account.Discovery.t list, Mentat_protocol.Error.t) result;
    model_readiness :
      ?refresh:bool ->
      unit ->
      (Mentat_provider.Model_readiness.t, Mentat_protocol.Error.t) result;
  }
end

module Settings = struct
  type t = {
    set_model :
      session:Mentat_session.Id.t ->
      ?reasoning_effort:Mentat_llm.Request.Options.Reasoning_effort.t ->
      Mentat_provider.Selector.t ->
      (unit, Mentat_protocol.Error.t) result;
    set_permission_review :
      session:Mentat_session.Id.t ->
      Mentat_permission.Review_behavior.t ->
      (unit, Mentat_protocol.Error.t) result;
    configuration :
      unit -> (Mentat_config.Resolved.View.t, Mentat_protocol.Error.t) result;
    set_default_model :
      ?reasoning_effort:Mentat_llm.Request.Options.Reasoning_effort.t ->
      Mentat_provider.Selector.t ->
      (unit, Mentat_protocol.Error.t) result;
    set_ui_theme : theme:string -> (unit, Mentat_protocol.Error.t) result;
  }
end

module Lifecycle = struct
  type t = {
    create :
      id:Mentat_session.Id.t ->
      title:string option ->
      (unit, Mentat_protocol.Error.t) result;
    rename :
      session:Mentat_session.Id.t ->
      title:string ->
      (unit, Mentat_protocol.Error.t) result;
    archive :
      session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
    restore :
      session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
    delete :
      session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
    set_goal :
      session:Mentat_session.Id.t ->
      goal:Mentat_session.Metadata.Goal.t option ->
      (unit, Mentat_protocol.Error.t) result;
    sessions :
      listing:Mentat_session.Listing.t ->
      ( Mentat_session.Summary.t list * Mentat_diagnostic.t list,
        Mentat_protocol.Error.t )
      result;
    session :
      Mentat_session.Id.t ->
      (Mentat_session.Session_view.t, Mentat_protocol.Error.t) result;
  }
end

module Review = struct
  type t = {
    apply : Mentat_review.Command.t -> (unit, Mentat_protocol.Error.t) result;
    state :
      scope:Mentat_review.Scope.t ->
      (Mentat_review.View.t, Mentat_protocol.Error.t) result;
    diff :
      path:Lpath.Rel.t ->
      (Mentat_review.File_diff.t option, Mentat_protocol.Error.t) result;
    crs :
      unit -> (Mentat_review.Cr.View.t list, Mentat_protocol.Error.t) result;
    compose : Mentat_review.Cr.Edit.t -> (unit, Mentat_protocol.Error.t) result;
  }
end

module Workspace = struct
  type t = {
    glance :
      unit -> (Textdiff.stats option, Mentat_protocol.Error.t) result;
    dune : unit -> (Mentat_workspace.Health.t, Mentat_protocol.Error.t) result;
    dune_control :
      op:[ `Restart | `Stop ] ->
      (Mentat_workspace.Health.t, Mentat_protocol.Error.t) result;
  }
end

type t = {
  session : Session.t;
  accounts : Accounts.t;
  settings : Settings.t;
  lifecycle : Lifecycle.t;
  review : Review.t;
  workspace : Workspace.t;
}
