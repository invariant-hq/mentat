(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let first_line text =
  match String.index_opt text '\n' with
  | Some i -> String.sub text 0 i
  | None -> text

let severity (severity : Ocamlc_loc.severity) =
  match severity with
  | Ocamlc_loc.Error _ -> Mentat_ocaml.Finding.Severity.Error
  | Ocamlc_loc.Warning _ | Ocamlc_loc.Alert _ ->
      Mentat_ocaml.Finding.Severity.Warning

(* The parser reports ocamlc's own spans: 1-based lines, 0-based
   end-exclusive character offsets — the same coordinates the stream's
   diagnostics carry, so both lanes render locations identically. *)
let location ~workspace (loc : Ocamlc_loc.loc) =
  match Mentat_workspace.resolve_string workspace loc.Ocamlc_loc.path with
  | Error _ -> (None, None)
  | Ok path -> (
      let start_line, end_line =
        match loc.Ocamlc_loc.lines with
        | Ocamlc_loc.Single line -> (line, line)
        | Ocamlc_loc.Range (start_line, end_line) -> (start_line, end_line)
      in
      let start_col, end_col =
        match loc.Ocamlc_loc.chars with
        | Some (start_col, end_col) -> (start_col, end_col)
        | None -> (0, 0)
      in
      match
        let start =
          Mentat_ocaml.Position.make ~line:(max 1 start_line)
            ~column:(max 0 start_col)
        in
        let end_ =
          Mentat_ocaml.Position.make ~line:(max 1 end_line)
            ~column:(max 0 end_col)
        in
        Mentat_ocaml.Location.make ~path
          ~range:(Mentat_ocaml.Range.make ~start ~end_)
      with
      | location ->
          ( Some (Mentat_workspace.Path.display path),
            Some (Format.asprintf "%a" Mentat_ocaml.Location.pp location) )
      | exception Invalid_argument _ ->
          (Some (Mentat_workspace.Path.display path), None))

let finding ~workspace (report : Ocamlc_loc.report) =
  let head =
    let head = String.trim (first_line (String.trim report.Ocamlc_loc.message)) in
    if String.is_empty head then "(no message)" else head
  in
  let path, location = location ~workspace report.Ocamlc_loc.loc in
  Mentat_ocaml.Finding.v ~lane:Mentat_ocaml.Finding.Lane.Lint
    ~severity:(severity report.Ocamlc_loc.severity)
    ?path ?location ~head ()

(* [Ocamlc_loc.parse] expects its input to begin at a diagnostic block —
   dune feeds it one action's captured output — and stops at the first
   unrecognized head, so leading chatter (a runner banner, progress lines)
   would swallow everything. Diagnostics begin at a zero-indent [File]
   line; everything before the first one is noise by construction. *)
let from_first_block output =
  let lines = String.split_on_char '
' output in
  let rec drop = function
    | [] -> []
    | line :: _ as rest when String.starts_with ~prefix:{|File "|} line ->
        rest
    | _ :: rest -> drop rest
  in
  String.concat "
" (drop lines)

let findings ~workspace output =
  List.map (finding ~workspace) (Ocamlc_loc.parse (from_first_block output))
