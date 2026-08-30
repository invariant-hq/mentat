(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Best-effort OS clipboard image probe for the interactive paste path.

    A terminal paste carries text, never the raster image a GUI paste would; to
    recover it, the interactive launch path reads the platform clipboard through
    a raster-clipboard tool (macOS [pngpaste], Wayland [wl-paste], X11 [xclip])
    spawned through the process manager. Absent every tool, or with a clipboard
    holding only text, it yields [None] and the ordinary text paste stands.
    Never raises. *)

val probe : stdenv:Eio_unix.Stdenv.base -> unit -> (string * string) option
(** [probe ~stdenv ()] tries the platform raster-clipboard tools in turn over
    [stdenv]'s process manager and returns the [(media_type, bytes)] of the
    first that yields image bytes a sniffer recognizes. A missing tool, a
    nonzero exit, or a clipboard with no image is [None], so an ordinary text
    paste is left undisturbed. *)
