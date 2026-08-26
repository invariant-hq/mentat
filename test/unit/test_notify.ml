(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Notify] — the shared notification hook. The module lives in
   [bin/boot] and is not library-linkable, so its source (with [Output], which
   it strips strings through) is copied into this test executable by the
   [copy_files] rule in [dune]. *)

open Windtrap

let with_env f =
  Eio_main.run @@ fun env ->
  f
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env)

let event mems =
  Output.Json.obj (List.map (fun (k, v) -> (k, Output.Json.string v)) mems)

let encoded mems =
  Output.Json.to_string (event mems) ^ "\n"

let stdin_delivery () =
  with_env @@ fun ~proc_mgr ~clock ->
  let out = Filename.temp_file "mentat-test-notify" ".json" in
  (* The hook reads one JSON line on stdin; control characters in string
     members are stripped before encoding, tab and newline surviving. *)
  Notify.fire ~proc_mgr ~clock
    ~argv:[ "/bin/sh"; "-c"; Printf.sprintf "cat > %s" (Filename.quote out) ]
    ~event:
      (event
         [ ("title", "esc\x1bape\x07"); ("body", "line1\nline2") ]);
  equal string ~msg:"the hook received the stripped event line"
    (encoded [ ("title", "escape"); ("body", "line1\nline2") ])
    (In_channel.with_open_bin out In_channel.input_all)

let best_effort () =
  with_env @@ fun ~proc_mgr ~clock ->
  (* A hook that cannot spawn, and one that exits non-zero, are both
     silent non-events; an empty argv fires nothing. *)
  Notify.fire ~proc_mgr ~clock
    ~argv:[ "/nonexistent/mentat-test-hook" ]
    ~event:(event [ ("title", "t") ]);
  Notify.fire ~proc_mgr ~clock
    ~argv:[ "/bin/sh"; "-c"; "exit 3" ]
    ~event:(event [ ("title", "t") ]);
  Notify.fire ~proc_mgr ~clock ~argv:[] ~event:(event [ ("title", "t") ]);
  is_true ~msg:"every failure path returned" true

let () =
  run "mentat.notify"
    [
      test "stdin delivery" stdin_delivery;
      test "best effort" best_effort;
    ]
