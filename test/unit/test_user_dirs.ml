(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [User_dirs]'s pure path policy — the per-session child
   socket derivation. The module lives in [bin/boot] and is not
   library-linkable, so its source is copied into this test executable by the
   [copy_files] rule in [dune]. *)

open Windtrap

let dirs () =
  let env =
    [
      ("MENTAT_CONFIG_HOME", "/home/u/.config/mentat");
      ("MENTAT_DATA_HOME", "/home/u/.local/share/mentat");
      ("MENTAT_STATE_HOME", "/home/u/.local/state/mentat");
      ("MENTAT_CACHE_HOME", "/home/u/.cache/mentat");
    ]
  in
  match User_dirs.resolve ~getenv:(fun k -> List.assoc_opt k env) with
  | Ok dirs -> dirs
  | Error message -> failf "resolve: %s" message

let socket_path dir = Filename.concat dir "mentat.sock"

let child_socket_derivation () =
  let dirs = dirs () in
  let base = User_dirs.daemon_socket_dir dirs in
  let leaf session =
    Filename.basename (User_dirs.child_socket_dir dirs ~session)
  in
  let under_s session =
    String.equal
      (Filename.dirname (User_dirs.child_socket_dir dirs ~session))
      (Filename.concat base "s")
  in
  (* A short filename-plain id is the leaf itself; anything else is keyed to
     16 hex characters. *)
  equal string ~msg:"a plain child id is admitted verbatim"
    "sub-0123456789abcdef"
    (leaf "sub-0123456789abcdef");
  let keyed = leaf (String.make 41 'a') in
  is_true ~msg:"an over-long id is keyed to 16 hex"
    (String.length keyed = 16
    && String.for_all
         (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
         keyed);
  is_true ~msg:"a 40-byte plain id is still verbatim"
    (String.equal (leaf (String.make 40 'a')) (String.make 40 'a'));
  is_true ~msg:"a path separator forces the keyed form"
    (String.length (leaf "a/b") = 16);
  is_true ~msg:"a leading dot forces the keyed form"
    (String.length (leaf "..") = 16);
  is_true ~msg:"the empty id is keyed, never an empty component"
    (String.length (leaf "") = 16);
  (* Determinism: the binder and a connecting broker derive the same path
     independently. *)
  equal string ~msg:"the derivation is a pure function of the id"
    (User_dirs.child_socket_dir dirs ~session:"a/b")
    (User_dirs.child_socket_dir dirs ~session:"a/b");
  is_true ~msg:"distinct ids key to distinct leaves"
    (not (String.equal (leaf "a/b") (leaf "a/c")));
  (* Both forms stay under the daemon's denied socket tree and inside the
     tightest (macOS, 104-byte) [sun_path] budget. *)
  is_true ~msg:"the verbatim form lives under <socket-dir>/s"
    (under_s "sub-0123456789abcdef");
  is_true ~msg:"the keyed form lives under <socket-dir>/s" (under_s "a/b");
  is_true ~msg:"a worst-case admissible id fits sun_path"
    (String.length
       (socket_path (User_dirs.child_socket_dir dirs ~session:(String.make 40 'a')))
    < 104);
  is_true ~msg:"the keyed form fits sun_path"
    (String.length
       (socket_path (User_dirs.child_socket_dir dirs ~session:(String.make 200 'x')))
    < 104)

(* The routine estate splits by home: policy under config, durable record
   under state, so removing the configuration can keep the audit trail. *)
let routine_paths () =
  let dirs = dirs () in
  equal string ~msg:"routines_dir lives under the config home"
    "/home/u/.config/mentat/routines"
    (User_dirs.routines_dir dirs);
  equal string ~msg:"routine_dir is the named routine's directory"
    "/home/u/.config/mentat/routines/pr-review"
    (User_dirs.routine_dir dirs "pr-review");
  equal string ~msg:"routine_state_dir lives under the state home"
    "/home/u/.local/state/mentat/routines/pr-review"
    (User_dirs.routine_state_dir dirs "pr-review");
  (* Run roots live under the cache home: every other home is denied to
     sandboxed runs as one of Mentat's own directories, and a workspace root
     inside a denied tree is refused at sandbox resolve. *)
  equal string ~msg:"routine_runs_dir lives under the cache home"
    "/home/u/.cache/mentat/routines/pr-review/runs"
    (User_dirs.routine_runs_dir dirs "pr-review")

let () =
  run "mentat.user_dirs"
    [
      test "child socket derivation" child_socket_derivation;
      test "routine paths" routine_paths;
    ]
