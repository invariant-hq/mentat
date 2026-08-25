(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Shared helpers for the per-tool boundary suites. Admission rule: a helper
   moves here only once it is duplicated, identically, in three or more test
   files and depends on nothing tool-specific (no [world], no per-tool
   fixtures). The failure branches of [encode]/[decode]/[finished]/[output_exn]
   are unreachable on the success paths the suites exercise, so their diagnostic
   wording is uniform here. *)

open Windtrap
module Json = Jsont.Json
module Tool = Mentat_tool

(* Workspace capability resolution *)

(* Every per-tool suite resolves one workspace capability the same way: no
   admitted roots, and — unless the suite is exercising a posture — full access
   over the whole read set with the network restricted. The resolution never
   fails on the fixtures the suites build, so its error arm is a uniform harness
   failure. [mode], [read], and [network] default here and are overridden only
   by the posture suites (shell overrides all three). *)
let resolve_exn ?(mode = Mentat_config.Mode.Danger_full_access)
    ?(read = Mentat_config.Read.All)
    ?(network = Mentat_sandbox.Policy.Network.Restricted) ~sw ~stdenv ~logical
    () =
  let environment = Mentat_workspace_io.process_environment () in
  match
    Mentat_workspace_io.resolve ~sw ~stdenv ~logical ~environment ~mode ~read
      ~readable_roots:[] ~writable_roots:[] ~mentat_dirs:[] ~network ()
  with
  | Ok io -> io
  | Error error ->
      failf "workspace capability resolution failed: %a"
        Mentat_workspace_io.Resolve_error.pp error

(* JSON construction and inspection *)

let json_object fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> failf "JSON encoding failed: %s" message

let json_member name = function
  | Jsont.Object (members, _) -> Option.map snd (Json.find_mem name members)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let rec json_member_names = function
  | Jsont.Object (members, _) ->
      List.concat_map
        (fun ((name, _), value) -> name :: json_member_names value)
        members
  | Jsont.Array (values, _) -> List.concat_map json_member_names values
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _ -> []

(* Durable codec round-tripping *)

let result_codec = Tool.Result.jsont Tool.Output.jsont

let encode codec value =
  match Json.encode codec value with
  | Ok json -> json
  | Error message -> failf "durable encoding failed: %s" message

let decode codec json =
  match Json.decode codec json with
  | Ok value -> value
  | Error message -> failf "durable decoding failed: %s" message

(* Tool result and call projections *)

let failure_name = function
  | `Invalid_input -> "invalid_input"
  | `Permission_denied -> "permission_denied"
  | `Not_found -> "not_found"
  | `Stale -> "stale"
  | `Unavailable -> "unavailable"
  | `Timed_out -> "timed_out"
  | `Failed -> "failed"

let finished = function
  | Tool.Call.Finished result -> result
  | Tool.Call.Prepared prepared ->
      failf "tool unexpectedly prepared: %s"
        (Tool.Prepared.description prepared)

let output_exn result =
  match Tool.Result.output result with
  | Some output -> output
  | None -> fail "tool result carried no output"

let model_call tool input =
  let name = Mentat_llm.Tool.name (Tool.declaration tool) in
  Mentat_llm.Tool.Call.make ~id:"tool-expect" ~name ~input ()

let print_case name = Printf.printf "-- %s --\n" name

(* Path and filesystem scaffolding *)

let rel path = Lpath.Rel.of_string_exn path
let root_key name = Mentat_workspace.Root.Key.of_string_exn name

let path_op_name = function
  | `Read -> "read"
  | `Create -> "create"
  | `Modify -> "modify"
  | `Delete -> "delete"

let mkdir path = Unix.mkdir path 0o755

let rec mkdir_p path =
  match Unix.mkdir path 0o755 with
  | () -> ()
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      mkdir_p (Filename.dirname path);
      mkdir path

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let read_disk path = In_channel.with_open_bin path In_channel.input_all

(* Scripted tool-peer installation. macOS runs a syspolicyd execution-policy
   assessment (~130ms) the first time a newly created executable inode is
   exec'd; a freshly written peer script per case would pay that on every
   spawn. Each distinct [script] is written once to a stable inode, which every
   case hardlinks into its own workspace at [path]: the path a case exec's is
   unchanged, but the shared inode is assessed only once per process. The peers
   are stateless — every per-case input travels through argv and stdin — so the
   shared inode changes nothing observable. A cross-filesystem [path] cannot be
   linked; there the case falls back to a private copy, correct but unshared. *)
let installed_peers : (string, string) Hashtbl.t = Hashtbl.create 8

let install_executable path script =
  let inode =
    match Hashtbl.find_opt installed_peers script with
    | Some inode -> inode
    | None ->
        let inode = Filename.temp_file "mentat-tool-peer-" "" in
        Out_channel.with_open_bin inode (fun channel ->
            Out_channel.output_string channel script);
        Unix.chmod inode 0o755;
        Hashtbl.replace installed_peers script inode;
        inode
  in
  match Unix.link inode path with
  | () -> ()
  | exception Unix.Unix_error (Unix.EXDEV, _, _) ->
      Out_channel.with_open_bin path (fun channel ->
          Out_channel.output_string channel script);
      Unix.chmod path 0o755
