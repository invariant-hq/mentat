(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Attach = Mentat_protocol.Attach
module Image = Mentat_llm.Image
module Content = Mentat_llm.Content

(* Validate and store already-materialized image bytes. The pure caps decision
   is {!Attach.check} (shared with the daemon composition); this supplies only
   the IO around it: downscale-on-oversize (before the check, so a retina
   screenshot a platform tool can shrink is accepted) and the blob store. *)
let store_bytes ~store ~caps ~downscale ~session bytes =
  let bytes =
    if String.length bytes > caps.Attach.max_bytes then
      Option.value
        (downscale ~bytes ~target_bytes:caps.Attach.max_bytes)
        ~default:bytes
    else bytes
  in
  match Attach.check caps bytes with
  | Error Attach.Rejection.Unsupported_format -> Error Attach.Error.Not_an_image
  | Error rejection -> Error (Attach.Error.Rejected rejection)
  | Ok format -> (
      match Mentat_store.Attachment.put store ~session bytes with
      | Ok reference ->
          Ok
            (Content.media
               ~media_type:(Image.Format.media_type format)
               (`Ref reference))
      | Error e ->
          Error
            (Attach.Error.Unavailable
               (Mentat_store.Attachment.Error.diagnostic ~session e)))

let attach ~store ~caps ~downscale ~read_path ~session source =
  match source with
  | Attach.Bytes { media_type = _; bytes } ->
      store_bytes ~store ~caps ~downscale ~session bytes
  | Attach.Path path -> (
      match read_path path with
      | Some bytes -> store_bytes ~store ~caps ~downscale ~session bytes
      | None -> Error Attach.Error.Not_found)
