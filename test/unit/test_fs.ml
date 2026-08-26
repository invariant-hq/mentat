(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Fs]'s ledger append and permission gate. The module lives
   in [bin/boot] and is not library-linkable, so its source is copied into
   this test executable by the [copy_files] rule in [dune]. The append tests
   run under [Eio_main]: append serializes in-process callers on a per-path
   [Eio.Mutex], so it must run inside a fiber. *)

open Windtrap

let temp_root () = Filename.temp_dir "mentat-test-fs" ""

let read path =
  In_channel.with_open_bin path In_channel.input_all

let write path bytes =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc bytes)

let ok ~msg = function
  | Ok value -> value
  | Error message -> failf "%s: %s" msg message

let append_ledger () =
  Eio_main.run @@ fun _env ->
  let root = temp_root () in
  let ledger = Filename.concat (Filename.concat root "state") "log.jsonl" in
  (* A fresh append creates the ledger — parent chain included — private. *)
  ok ~msg:"fresh append" (Fs.append ledger {|{"a":1}|});
  equal string ~msg:"the record is newline-framed" "{\"a\":1}\n" (read ledger);
  is_true ~msg:"the ledger is owner-only"
    ((Unix.stat ledger).Unix.st_perm land 0o077 = 0);
  ok ~msg:"second append" (Fs.append ledger {|{"b":2}|});
  equal string ~msg:"records accumulate in order" "{\"a\":1}\n{\"b\":2}\n"
    (read ledger);
  (* A torn, newline-less tail — an interrupted writer's artifact — is
     truncated to the last record boundary before the new record lands. *)
  write ledger "{\"a\":1}\n{\"b\":2}\n{\"torn";
  ok ~msg:"append over a torn tail" (Fs.append ledger {|{"c":3}|});
  equal string ~msg:"the torn tail is gone, the record boundary holds"
    "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n" (read ledger);
  (* A ledger that is one torn fragment truncates to empty, then appends. *)
  write ledger "half-a-record";
  ok ~msg:"append over an all-torn ledger" (Fs.append ledger {|{"d":4}|});
  equal string ~msg:"only the fresh record remains" "{\"d\":4}\n" (read ledger);
  (* A raw newline inside a record would forge a boundary; refused. *)
  (match Fs.append ledger "two\nlines" with
  | Ok () -> fail "a record with a newline must be refused"
  | Error message ->
      is_true ~msg:"the refusal names the newline"
        (String.length message > 0));
  equal string ~msg:"the refused record left no bytes" "{\"d\":4}\n"
    (read ledger)

(* Two fibers interleaving appends: the per-path mutex serializes them, so
   every record lands whole and framed. *)
let append_concurrent_fibers () =
  Eio_main.run @@ fun _env ->
  let root = temp_root () in
  let ledger = Filename.concat root "log.jsonl" in
  let write tag =
    for i = 1 to 20 do
      ok ~msg:"fiber append" (Fs.append ledger (Printf.sprintf "%s-%d" tag i))
    done
  in
  Eio.Fiber.both (fun () -> write "a") (fun () -> write "b");
  let lines =
    String.split_on_char '\n' (read ledger)
    |> List.filter (fun l -> not (String.equal l ""))
  in
  equal int ~msg:"all records landed" 40 (List.length lines);
  List.iter
    (fun line ->
      is_true ~msg:"each record is whole"
        (String.length line > 2
        && (String.starts_with ~prefix:"a-" line
           || String.starts_with ~prefix:"b-" line)))
    lines

let require_private () =
  let root = temp_root () in
  let file mode name =
    let path = Filename.concat root name in
    write path "secret";
    Unix.chmod path mode;
    path
  in
  (match Fs.require_private (file 0o600 "tight") with
  | Ok () -> ()
  | Error message -> failf "0600 refused: %s" message);
  (match Fs.require_private (file 0o640 "group-read") with
  | Ok () -> fail "0640 must be refused"
  | Error message ->
      is_true ~msg:"the refusal names the mode"
        (String.length message > 0));
  (match Fs.require_private (file 0o604 "world-read") with
  | Ok () -> fail "0604 must be refused"
  | Error _ -> ());
  (match Fs.require_private root with
  | Ok () -> ()
  | Error message -> failf "a 0700 directory refused: %s" message);
  match Fs.require_private (Filename.concat root "absent") with
  | Ok () -> fail "a missing entry is not a private one"
  | Error _ -> ()

let () =
  run "mentat.fs"
    [
      test "ledger append" append_ledger;
      test "concurrent fibers serialize on the ledger" append_concurrent_fibers;
      test "require_private" require_private;
    ]
