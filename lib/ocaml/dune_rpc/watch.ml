(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type word = Defer | Announce of Mentat_workspace.Health.t

let compose word ~observed =
  match (word, observed) with
  | _, (Mentat_workspace.Health.Live _ as live) -> live
  | Defer, observed -> observed
  | Announce health, _ -> health

let after_death ~reached ~deaths =
  let deaths = if reached then 0 else deaths + 1 in
  if deaths >= 2 then `Give_up else `Retry deaths

(* A leading word is an assignment when its ['='] precedes any ['/']: POSIX
   makes [VAR=value cmd] an assignment whatever the value holds, while a
   program path containing ['='] puts a ['/'] first. *)
let assignment token =
  match String.index_opt token '=' with
  | None -> false
  | Some equals -> (
      equals > 0
      &&
      match String.index_opt token '/' with
      | None -> true
      | Some slash -> equals < slash)

let whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

let forwards_into_watch ~command =
  let words =
    String.map (fun char -> if whitespace char then ' ' else char) command
    |> String.split_on_char ' '
    |> List.filter (fun token -> not (String.is_empty token))
  in
  let rec program = function
    | [] -> None
    | token :: rest -> if assignment token then program rest else Some token
  in
  match program words with
  | Some token -> String.equal (Filename.basename token) "dune"
  | None -> false
