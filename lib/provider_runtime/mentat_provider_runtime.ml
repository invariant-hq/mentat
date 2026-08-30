(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Store_error = Store_error
module Error = Error
module Artifact = Artifact

type t = Runtime.t

let create = Runtime.create
let catalog = Runtime.catalog

(* Filter law. Every wrapper below is a [Mentat_llm.Client.t -> Client.t] that
   re-runs the SAME [Request.t] — same body, same [Mentat_llm.Request.digest].
   Request identity and deduplication live above this layer, keyed on the digest
   the planner commits; a wrapper here may prepare weights, refresh a credential,
   or retry, but it must never rewrite the request. Prompt-munging would change
   the digest upstream already trusts and defeat the dedup it keys. Because
   authentication rides in headers, below the digest boundary, even a refreshed
   credential re-runs a byte-identical request. A wrapper carries the inner
   client's acceptance data verbatim: widening it would let preparation work
   start for a model the inner client then rejects. *)

(* The artifact-prepare gate: a local client prepares its weights transparently
   on first request. Preparation progress is forwarded to [on_progress] so the
   frontend can render a download line; a provider with nothing to prepare
   never emits. *)
let with_artifact_prepare ~sw ~env ~on_progress artifact model client =
  match artifact with
  | None -> client
  | Some { Driver.prepare; _ } ->
      let prepared = ref false in
      let preparing = Eio.Mutex.create () in
      let run ~cancelled ~on_event request =
        let preparation =
          if !prepared then Ok ()
          else
            Eio.Mutex.use_ro preparing (fun () ->
                if !prepared then Ok ()
                else
                  match
                    prepare ~sw ~env ~cancelled ~observe:on_progress model
                  with
                  | Error _ as error -> error
                  | Ok () ->
                      prepared := true;
                      Ok ())
        in
        match preparation with
        | Error _ as error -> error
        | Ok () ->
            Mentat_llm.Client.response ~cancelled ~on_event client request
      in
      Mentat_llm.Client.make
        ~provider:(Mentat_llm.Client.provider client)
        ~apis:(Mentat_llm.Client.apis client)
        ~run

(* One reactive refresh on a [Startup]-phase [Auth] failure: refresh, rebuild,
   retry the same request once. A second failure returns; no loop. *)
let with_refresh_retry ~rebuild ~refresh credential client =
  let provider = Mentat_llm.Client.provider client in
  let apis = Mentat_llm.Client.apis client in
  let current = ref (client, credential) in
  let refreshing = Eio.Mutex.create () in
  let run ~cancelled ~on_event request =
    let client, credential = !current in
    match Mentat_llm.Client.response ~cancelled ~on_event client request with
    | Error error as result -> (
        match (Mentat_llm.Error.kind error, Mentat_llm.Error.phase error) with
        | Mentat_llm.Error.Auth, Mentat_llm.Error.Startup -> (
            (* Guarded and double-checked like [with_artifact_prepare]: a
               concurrent fiber that already refreshed past [client] is observed
               through [current], so only one refresh fires per stale client. *)
            let refreshed =
              Eio.Mutex.use_ro refreshing (fun () ->
                  let installed_client, _ = !current in
                  if installed_client != client then Ok (Some !current)
                  else
                    match refresh credential with
                    | Ok (Some credential) -> (
                        match rebuild credential with
                        | Ok client ->
                            current := (client, credential);
                            Ok (Some (client, credential))
                        | Error error -> Error (Error.to_llm error))
                    | Error error -> Error (Error.to_llm error)
                    | Ok None -> Ok None)
            in
            match refreshed with
            | Ok (Some (client, _)) ->
                Mentat_llm.Client.response ~cancelled ~on_event client request
            | Ok None -> result
            | Error _ as error -> error)
        | _ -> result)
    | result -> result
  in
  Mentat_llm.Client.make ~provider ~apis ~run

let client t ~sw ~env ~now ?base_url ?auth_base_url ?(process = [])
    ?(on_artifact_progress = fun (_ : Artifact.Progress.t) -> ()) ~environment
    ?name model =
  let provider = Mentat_llm.Model.provider model in
  match Runtime.registration_for t provider with
  | None -> Error (Error.Unknown_provider provider)
  | Some reg -> (
      let driver = reg.Driver.driver in
      let declaration = reg.Driver.declaration in
      let wrap client =
        with_artifact_prepare ~sw ~env ~on_progress:on_artifact_progress
          driver.Driver.artifact model client
      in
      let build_bare () =
        Result.map wrap (driver.Driver.build_client ~sw ~env ?base_url None)
      in
      match Credential_store.load (Runtime.store t) with
      | Error store_error -> Error (Error.Store store_error)
      | Ok store -> (
          match
            Mentat_provider.resolve_credential declaration ~process ~environment
              ~store ?name ()
          with
          | Error error -> Error (Error.Credential { provider; error })
          | Ok None -> build_bare ()
          | Ok (Some credential) -> (
              match
                Account_ops.refresh t ~sw ~env ~now ?auth_base_url credential
              with
              | Error _ as error -> error
              | Ok None -> build_bare ()
              | Ok (Some credential) -> (
                  let build credential =
                    Result.map wrap
                      (driver.Driver.build_client ~sw ~env ?base_url
                         (Some credential))
                  in
                  match build credential with
                  | Error _ as error -> error
                  | Ok client -> (
                      match
                        ( driver.Driver.refresh,
                          Mentat_provider.Credential.kind credential )
                      with
                      | Some _, Mentat_provider.Credential.Kind.OAuth ->
                          let refresh credential =
                            Account_ops.refresh t ~sw ~env ~now ~force:true
                              ?auth_base_url credential
                          in
                          Ok
                            (with_refresh_retry ~rebuild:build ~refresh
                               credential client)
                      | _ -> Ok client)))))

let discover_accounts = Account_ops.load
let refresh_listings = Account_ops.refresh_listings
let listings = Account_ops.listings

module Login = Login_flow

module Loopback = struct
  let await_once ~stdenv ?provider ?on_ready ?accept ?serve ~redirect_uri
      ~timeout_s () =
    Result.map_error Oauth_flow.Error.message
      (Oauth_flow.Local_callback.await_once ~stdenv ?provider ?on_ready
         ?accept ?serve ~redirect_uri ~timeout_s ())
end

module Local = struct
  let status t model =
    match Runtime.registration_for t (Mentat_llm.Model.provider model) with
    | None -> None
    | Some reg -> (
        match reg.Driver.driver.Driver.artifact with
        | None -> None
        | Some artifact -> artifact.Driver.status model)

  let download t ~sw ~env ~force ~observe model =
    match Runtime.registration_for t (Mentat_llm.Model.provider model) with
    | None -> Artifact.Download_outcome.Not_downloadable
    | Some reg -> (
        match reg.Driver.driver.Driver.artifact with
        | None -> Artifact.Download_outcome.Not_downloadable
        | Some artifact ->
            artifact.Driver.download ~sw ~env ~force ~observe model)
end
