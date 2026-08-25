(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The engine's provider function over [mentat.provider_runtime].

    The engine names no provider; one {!Mentat_agent.Ports.provider_call} serves
    every model because the model rides the request. The function reads
    {!Mentat_llm.Request.model}, builds a credentialed {!Mentat_llm.Client.t}
    from the current credential store for each claimed provider request through
    {!Mentat_provider_runtime.client}, and dispatches with
    {!Mentat_llm.Client.response}. A build error therefore surfaces after the
    provider claim as a {!Mentat_llm.Error.t} (via [Error.to_llm]) — the port
    has no pre-claim preparation hook. No client survives the request that
    selected its credentials. *)

val make :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  now:(unit -> Mentat_provider.Credential.timestamp) ->
  runtime:Mentat_provider_runtime.t ->
  base_url:(Mentat_llm.Provider.t -> string option) ->
  auth_base_url:(Mentat_llm.Provider.t -> string option) ->
  environment:(string * string) list ->
  unit ->
  Mentat_agent.Ports.provider_call
(** [make ~sw ~env ~now ~runtime ~base_url ~auth_base_url ~environment ()] is
    the provider call. [base_url]/[auth_base_url] are resolved per the model's
    provider on each request; [environment] is the credential snapshot the
    executable captured at startup. Stored credentials are loaded live by each
    request, so a completed save or logout affects the next call. *)
