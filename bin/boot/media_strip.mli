(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The (channel, provider/API, model) vision gate: strip a media block the
    active model or API cannot carry, replacing it with a text placeholder.

    The gate is executable-side because the vision flag is catalog metadata and
    the encodability table is [mentat.provider] — neither of which the
    ports-only engine links. A media block is stripped when the model lacks the
    image input modality, or when the API cannot encode media in the block's
    channel. The durable journal keeps the reference, so a later turn on a
    capable model still sees the history; only this request is stripped. *)

val apply :
  catalog:Mentat_provider.Catalog.t ->
  Mentat_llm.Request.t ->
  Mentat_llm.Request.t
(** [apply ~catalog request] returns [request] with every user-content media
    block the active model or its API cannot carry replaced by a placeholder
    text block naming the reason. A request whose model is vision-capable and
    whose media is all encodable is returned unchanged. An unknown model (absent
    from [catalog]) is assumed capable — the API decides. *)
