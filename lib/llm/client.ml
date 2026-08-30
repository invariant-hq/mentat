(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type cancellation = unit -> bool

type run =
  cancelled:cancellation ->
  on_event:(Event.t -> unit) ->
  Request.t ->
  (Response.t, Error.t) result

type t = { provider : Provider.t; apis : Model.Api.t list; run : run }

let make ~provider ~apis ~run = { provider; apis; run }
let provider t = t.provider
let apis t = t.apis

let accepts t model =
  Provider.equal t.provider (Model.provider model)
  && List.exists (Model.Api.equal (Model.api model)) t.apis

let invalid_model t request =
  let requested = Request.model request in
  let message =
    Format.asprintf "client provider %a serving apis %a cannot run model %a"
      Provider.pp t.provider
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
         Model.Api.pp)
      t.apis Model.pp requested
  in
  Error (Error.make ~kind:Error.Invalid_request ~provider:t.provider message)

let not_cancelled () = false
let no_event _ = ()

let response ?(cancelled = not_cancelled) ?(on_event = no_event) t request =
  if accepts t (Request.model request) then t.run ~cancelled ~on_event request
  else invalid_model t request
