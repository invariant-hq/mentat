(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Path = Mentat_workspace.Path

type t = {
  workspace_io : Mentat_workspace_io.t;
  toolchain : Mentat_ocaml_toolchain.t;
}

type error =
  | Invalid_tool of string
  | Workspace_path of Mentat_workspace.Resolve_error.t
  | File_observation of Mentat_workspace_io.File_error.t
  | Address of Mentat_workspace.Resolve_error.t
  | Binary_not_found of string

let make workspace_io ~toolchain = { workspace_io; toolchain }

let error_message error =
  let text =
    match error with
    | Invalid_tool tool ->
        Printf.sprintf
          "could not resolve the Dune dev-tool Merlin binary: %S is not a \
           single tool name"
          tool
    | Workspace_path error ->
        "could not resolve the Dune dev-tool Merlin binary: "
        ^ Mentat_workspace.Resolve_error.message error
    | File_observation error ->
        Format.asprintf "could not resolve the Dune dev-tool Merlin binary: %a"
          Mentat_workspace_io.File_error.pp error
    | Address error ->
        "could not resolve the Dune dev-tool Merlin binary: "
        ^ Mentat_workspace.Resolve_error.message error
    | Binary_not_found tool ->
        Printf.sprintf
          "could not resolve the Dune dev-tool Merlin binary: no built %s was \
           found under _build/_private/*/.dev-tool"
          tool
  in
  text

let resolve_program t program =
  match Mentat_ocaml_toolchain.find t.toolchain program with
  | Some (absolute, _) -> [ absolute ]
  | None -> [ program ]

let add_component path component =
  match Path.add_component path component with
  | Ok path -> Ok path
  | Error _ -> Error (Invalid_tool component)

let add_literal path component =
  match Path.add_component path component with
  | Ok path -> path
  | Error _ ->
      (* Every caller supplies a static, valid component. *)
      assert false

let read_dir t path =
  match Mentat_workspace_io.File.read_dir t.workspace_io path with
  | Ok entries -> Ok entries
  | Error (Mentat_workspace_io.File_error.Not_found _) -> Ok []
  | Error error -> Error (File_observation error)

let existing_regular_file t path =
  match Mentat_workspace_io.File.stat t.workspace_io path with
  | Ok stat -> Ok (stat.Eio.File.Stat.kind = `Regular_file)
  | Error (Mentat_workspace_io.File_error.Not_found _) -> Ok false
  | Error error -> Error (File_observation error)

let absolute t path =
  match Mentat_workspace_io.to_abs t.workspace_io path with
  | Ok path -> Ok (Lpath.Abs.to_string path)
  | Error error -> Error (Address error)

(* Dune writes dev-tool binaries below
   [_build/_private/<context>/.dev-tool/<package>/target/bin]. Contexts and
   packages are traversed in [File.read_dir]'s stable name order. *)
let find_dev_tool t tool =
  let ( let* ) = Result.bind in
  let* private_root =
    Result.map_error
      (fun error -> Workspace_path error)
      (Mentat_workspace_io.resolve_path t.workspace_io "_build/_private")
  in
  let* contexts = read_dir t private_root in
  let rec find_context = function
    | [] -> Ok None
    | context :: rest ->
        let dev_tool_root = add_literal context ".dev-tool" in
        let* packages = read_dir t dev_tool_root in
        let rec find_package = function
          | [] -> find_context rest
          | package :: rest ->
              let bin =
                package |> fun path ->
                add_literal path "target" |> fun path -> add_literal path "bin"
              in
              let* candidate = add_component bin tool in
              let* exists = existing_regular_file t candidate in
              if exists then Result.map Option.some (absolute t candidate)
              else find_package rest
        in
        find_package packages
  in
  find_context contexts

let dune_tools_exec_tool = function
  | [ dune; "tools"; "exec"; tool; "--" ]
    when String.equal (Filename.basename dune) "dune" ->
      Some tool
  | _ -> None

let bare_program = function
  | [ token ]
    when (not (String.is_empty token))
         && String.equal (Filename.basename token) token ->
      Some token
  | _ -> None

let resolve_merlin t ~configured =
  match configured with
  | [] ->
      invalid_arg
        "Tool_boot.resolve_merlin: configured prefix must not be empty"
  | _ -> (
      match dune_tools_exec_tool configured with
      | Some tool -> (
          match find_dev_tool t tool with
          | Error _ as error -> error
          | Ok (Some binary) -> Ok [ binary ]
          | Ok None -> Error (Binary_not_found tool))
      | None -> (
          match bare_program configured with
          | None -> Ok configured
          | Some tool -> (
              match Mentat_ocaml_toolchain.find t.toolchain tool with
              | Some (absolute, _) -> Ok [ absolute ]
              | None -> (
                  match find_dev_tool t tool with
                  | Error _ as error -> error
                  | Ok (Some binary) -> Ok [ binary ]
                  | Ok None -> Ok configured))))
