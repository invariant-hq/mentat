(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Drpc = Dune_rpc.Private

type t = { file : string }

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdir_p parent;
    try Unix.mkdir dir 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write ~env ~root ~pid ~socket =
  match
    let config = Drpc.Registry.Config.create (Xdg.create ~env ()) in
    let entry = Drpc.Registry.Dune.create ~where:(`Unix socket) ~root ~pid in
    let (`Caller_should_write file) =
      Drpc.Registry.Config.register config entry
    in
    let path = file.Drpc.Registry.File.path in
    mkdir_p (Filename.dirname path);
    let out = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr out)
      (fun () -> output_string out file.Drpc.Registry.File.contents);
    path
  with
  | file -> Ok { file }
  | exception exn -> Error (Printexc.to_string exn)

let path t = t.file

let remove t =
  match Unix.unlink t.file with
  | () -> ()
  | exception Unix.Unix_error _ -> ()
