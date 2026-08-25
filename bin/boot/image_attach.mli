(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The executable's IO half of the attach request/completion flow.

    It holds the capabilities the pure App and the engine lack — a file read
    (for a path source), the platform downscale spawn, and the fence-free
    attachment store — around the pure caps policy
    {!Mentat_protocol.Attach.check}, and turns an image into the model-visible
    content block a prompt later carries, or a typed refusal. *)

val attach :
  store:Mentat_store.t ->
  caps:Mentat_protocol.Attach.caps ->
  downscale:(bytes:string -> target_bytes:int -> string option) ->
  read_path:(Mentat_workspace.Path.t -> string option) ->
  session:Mentat_session.Id.t ->
  Mentat_protocol.Attach.source ->
  (Mentat_llm.Content.t, Mentat_protocol.Attach.Error.t) result
(** [attach ~store ~caps ~downscale ~read_path ~session source] resolves
    [source] to image bytes ([read_path] for a path, else the given bytes),
    downscales them toward [caps.max_bytes] on oversize via [downscale]
    (best-effort; [None] when no platform tool is present), applies
    {!Mentat_protocol.Attach.check} for format/size/dimension, stores the bytes
    in [session]'s attachment namespace, and returns the [`Ref] media block.
    [read_path] returns [None] when a path does not resolve to a readable file.
*)
