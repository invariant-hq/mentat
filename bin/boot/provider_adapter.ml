(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Runtime = Mentat_provider_runtime

(* Adapt the runtime's provider-neutral artifact vocabulary onto the protocol's
   model-download pulse — the executable is the sole seam that knows both. *)
let model_download (progress : Runtime.Artifact.Progress.t) =
  let phase =
    match progress.Runtime.Artifact.Progress.phase with
    | Runtime.Artifact.Progress.Checking ->
        Mentat_protocol.Progress.Model_download.Checking
    | Runtime.Artifact.Progress.Downloading ->
        Mentat_protocol.Progress.Model_download.Downloading
    | Runtime.Artifact.Progress.Verifying ->
        Mentat_protocol.Progress.Model_download.Verifying
    | Runtime.Artifact.Progress.Ready ->
        Mentat_protocol.Progress.Model_download.Ready
  in
  {
    Mentat_protocol.Progress.Model_download.model =
      progress.Runtime.Artifact.Progress.model;
    received = progress.Runtime.Artifact.Progress.received;
    total = progress.Runtime.Artifact.Progress.total;
    phase;
  }

let make ~sw ~env ~now ~runtime ~base_url ~auth_base_url ~environment () :
    Mentat_agent.Ports.provider_call =
 fun request ~on_event ~on_download ~cancelled ->
  let model = Mentat_llm.Request.model request in
  let provider = Mentat_llm.Model.provider model in
  let on_artifact_progress progress = on_download (model_download progress) in
  match
    Runtime.client runtime ~sw ~env ~now:(now ()) ?base_url:(base_url provider)
      ?auth_base_url:(auth_base_url provider) ~process:[] ~on_artifact_progress
      ~environment model
  with
  | Error e -> Error (Runtime.Error.to_llm e)
  | Ok client -> Mentat_llm.Client.response ~cancelled ~on_event client request
