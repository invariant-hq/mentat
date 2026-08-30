(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Render a session's durable [Fact.t] projection to one self-contained HTML
    document. Pure: [Fact.t] stream in, HTML [string] out, no IO. The store
    read, the [Projection.all] call, and the file write are the caller's
    ([cli_session.ml]).

    The document is a single [<!doctype html>] file with an inlined [<style>], a
    hash-pinned CSP [<meta>], one small expand/collapse [<script>], and every
    fact fragment in order. It references no external host: images arrive inline
    as [data:] URIs and untrusted fact text reaches HTML only through the one
    escaping path or [cmarkit ~safe:true], so a poisoned tool result cannot
    inject markup. The module is kept library-shaped — pure, IO-free, linking
    only value vocabularies — so it lifts into a [mentat.transcript] library
    when a second consumer ([mentat.web]) arrives. *)

module Options : sig
  type t
  (** Rendering knobs. Immutable; {!default} is the everyday choice. *)

  val default : t
  (** [default] renders with the automatic (prefers-color-scheme) theme, a
      "generated at" stamp omitted, no quiet filtering, and the generous default
      byte caps below. A normal session inlines fully under these. *)

  val make :
    ?theme:[ `Auto | `Light | `Dark ] ->
    ?max_tool_bytes:int ->
    ?max_image_bytes:int ->
    ?max_total_bytes:int ->
    ?timestamp:Mentat_session.Time.t ->
    ?quiet:bool ->
    unit ->
    t
  (** [make ?theme ?max_tool_bytes ?max_image_bytes ?max_total_bytes ?timestamp
       ?quiet ()] is a set of rendering knobs.

      [theme] selects the colour scheme: [`Auto] (default) follows the reader's
      [prefers-color-scheme]; [`Light] and [`Dark] pin one. [max_tool_bytes]
      (default 100_000) caps each tool-output body; a longer body is truncated
      with a visible marker. [max_image_bytes] (default 2_000_000) caps a single
      inlined image; a larger image becomes a labelled placeholder chip.
      [max_total_bytes] (default 50_000_000) is the whole-document guard
      {!render} enforces. [timestamp], when present, stamps the header with a
      "generated at" line; omit it for byte-reproducible output. [quiet]
      (default [false]) drops low-signal queue chatter. *)
end

type head = {
  id : Mentat_session.Id.t;
  title : string option;
  metadata : Mentat_session.Metadata.t;
      (** Workspace directory, lifecycle, lineage, and saved times. *)
  metrics : Mentat_session.Metrics.t option;
      (** Token, turn, and tool totals for the header; [None] when the metric
          fold overflowed and the caller degraded rather than crash the exit
          ladder — the header then omits the totals row. *)
}
(** The run header a document paints above the transcript. A plain record — the
    caller fills it from the session's own metadata and metrics projections. *)

val render :
  ?options:Options.t ->
  ?resolve_media:(Mentat_digest.Content_ref.t -> string option) ->
  head ->
  (Mentat_protocol.Position.t * Mentat_protocol.Fact.t) list ->
  (string, [ `Too_large of int ]) result
(** [render ?options ?resolve_media head facts] is a complete self-contained
    HTML document: an inlined [<style>], the hash-pinned CSP [<meta>], the
    expand/collapse [<script>], the branded run header from [head], and every
    fact fragment of [facts] in order.

    [resolve_media] loads the attachment bytes a [`Ref] media block references,
    supplied by the CLI, which holds the store; the module itself never reads a
    store. A resolved reference embeds the real image as a [data:] URI, an
    unresolved one (the default [fun _ -> None]) keeps a self-contained
    placeholder. The export never references an external host either way.

    It is [Error (`Too_large n)] iff the assembled document is [n] bytes and [n]
    exceeds [options]' [max_total_bytes] — the caller fails loudly and points at
    [--format json] for a full archive. Otherwise it is [Ok html]. No IO in the
    module; [resolve_media] may read the store. *)
