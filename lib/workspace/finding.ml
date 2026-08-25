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

(* The lint marker: the head's last token is [" [<rule>]"] with a
   lowercase-alphanumeric-hyphen rule name — the convention a lint tool
   running as a build rule uses, because the build tool's wire drops the rule
   identity before a client can read it. *)
let has_lint_marker head =
  let len = String.length head in
  if len < 4 || head.[len - 1] <> ']' then false
  else
    match String.rindex_opt head '[' with
    | None -> false
    | Some open_at ->
        open_at >= 1
        && head.[open_at - 1] = ' '
        && open_at + 1 < len - 1
        && (match head.[open_at + 1] with 'a' .. 'z' -> true | _ -> false)
        && String.for_all
             (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
             (String.sub head (open_at + 1) (len - 1 - (open_at + 1)))

let classify ~lint ~severity ?path ?location ~head () =
  let lane = if lint && has_lint_marker head then Lane.Lint else Lane.Build in
  v ~lane ~severity ?path ?location ~head ()

let lane t = t.lane
let severity t = t.severity
let path t = t.path
let location t = t.location
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

let equal a b = String.equal (key a) (key b)

let pp ppf t =
  Format.fprintf ppf "@[<h>%a/%a %s@]" Lane.pp t.lane Severity.pp t.severity
    (body_line t)
