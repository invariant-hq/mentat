(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Image = Mentat_llm.Image

(* Spawn [argv] and return its captured stdout bytes, or [None] when the tool is
   missing or exits nonzero. stderr is discarded; a raster clipboard tool prints
   the image bytes to stdout. *)
let run_out process_mgr argv =
  try
    let discard = Buffer.create 64 in
    Some
      (Eio.Process.parse_out process_mgr Eio.Buf_read.take_all
         ~stderr:(Eio.Flow.buffer_sink discard)
         argv)
  with _ -> None

(* Best-effort OS clipboard image probe through the sealed spawn boundary. Tries
   the platform raster-clipboard tools in turn; the first that yields sniffable
   image bytes wins. A missing tool or a clipboard with no image is a clean
   [None], so an ordinary text paste is undisturbed. *)
let probe ~stdenv () =
  let process_mgr = Eio.Stdenv.process_mgr stdenv in
  let attempts =
    [
      [ "pngpaste"; "-" ];
      [ "wl-paste"; "--type"; "image/png"; "--no-newline" ];
      [ "xclip"; "-selection"; "clipboard"; "-t"; "image/png"; "-o" ];
    ]
  in
  let rec try_tools = function
    | [] -> None
    | argv :: rest -> (
        match run_out process_mgr argv with
        | Some bytes -> (
            match Image.sniff bytes with
            | Some format -> Some (Image.Format.media_type format, bytes)
            | None -> try_tools rest)
        | None -> try_tools rest)
  in
  try_tools attempts
