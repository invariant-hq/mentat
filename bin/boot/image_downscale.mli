(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Best-effort image downscaling through a platform tool.

    The binding cap is the byte cap, and the commonest oversize is a retina PNG
    screenshot; rather than an in-process codec, v1 shrinks it with a platform
    tool (macOS [sips], then ImageMagick [magick]/[convert]) spawned through the
    process manager. Absent every tool, it returns [None] and the caller
    caps-rejects. Never raises. *)

val run :
  stdenv:Eio_unix.Stdenv.base ->
  bytes:string ->
  target_bytes:int ->
  string option
(** [run ~stdenv ~bytes ~target_bytes] shrinks [bytes] toward [target_bytes] by
    resizing with the first available platform tool, returning the smaller image
    bytes, or [None] when no tool is present or the resize did not yield a
    smaller valid image. The dimension target is estimated from the current
    byte/pixel ratio. *)
