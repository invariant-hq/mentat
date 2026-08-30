(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type provider_call =
  Mentat_llm.Request.t ->
  on_event:(Mentat_llm.Event.t -> unit) ->
  on_download:(Mentat_protocol.Progress.Model_download.t -> unit) ->
  cancelled:(unit -> bool) ->
  (Mentat_llm.Response.t, Mentat_llm.Error.t) result

let script call request ~on_event:_ ~on_download:_ ~cancelled:_ = call request

type workspace = {
  identity : Mentat_sandbox.Identity.t;
  checkpoint :
    boundary:Mentat_mutation.Checkpoint.boundary -> Mentat_mutation.Checkpoint.t;
  drain_notices : unit -> Mentat_workspace.Notice.t list;
  open_scope :
    Mentat_session.Tool_claim.Id.t -> unit -> Mentat_edit.Apply_evidence.t;
}
