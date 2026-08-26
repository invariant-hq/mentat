(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Lane = struct
  type t = Build | Lint

  let equal a b =
    match (a, b) with
    | Build, Build | Lint, Lint -> true
    | (Build | Lint), _ -> false

  let pp ppf = function
    | Build -> Format.pp_print_string ppf "build"
    | Lint -> Format.pp_print_string ppf "lint"
end

module Severity = struct
  type t = Error | Warning

  let equal (a : t) (b : t) =
    match (a, b) with
    | Error, Error | Warning, Warning -> true
    | (Error | Warning), _ -> false

  let pp ppf (t : t) =
    match t with
    | Error -> Format.pp_print_string ppf "error"
    | Warning -> Format.pp_print_string ppf "warning"
end

type t = {
  lane : Lane.t;
  severity : Severity.t;
  path : string option;
  location : string option;
  head : string;
}

let v ~lane ~severity ?path ?location ~head () =
  if String.is_empty head then invalid_arg "finding head must not be empty";
  if String.contains head '\n' then
    invalid_arg "finding head must be a single line";
  { lane; severity; path; location; head }

let lane t = t.lane
let severity t = t.severity
let path t = t.path
let head t = t.head

let key t =
  String.concat "\000"
    [
      (match t.lane with Lane.Build -> "build" | Lane.Lint -> "lint");
      (match t.severity with
      | Severity.Error -> "error"
      | Severity.Warning -> "warning");
      Option.value t.path ~default:"";
      t.head;
    ]

let body_line t =
  match t.location with
  | Some location -> location ^ ": " ^ t.head
  | None -> t.head

let head_of_message message =
  let first_line text =
    match String.index_opt text '\n' with
    | Some i -> String.sub text 0 i
    | None -> text
  in
  let head = String.trim (first_line (String.trim message)) in
  if String.is_empty head then "(no message)" else head

let rendered_location location =
  ( Mentat_workspace.Path.display (Location.path location),
    Format.asprintf "%a" Location.pp location )
