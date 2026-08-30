(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { prefix : string list; chdir : bool; digest : Mentat_digest.t }

let domain = "mentat.sandbox.profile.v1"

let seatbelt policy =
  let sbpl, params = Seatbelt.sbpl policy in
  let prefix =
    (Backend.executable Backend.Seatbelt :: [ "-p"; sbpl ])
    @ List.map (fun (key, value) -> "-D" ^ key ^ "=" ^ value) params
    @ [ "--" ]
  in
  let parts = sbpl :: List.map (fun (key, value) -> key ^ "=" ^ value) params in
  { prefix; chdir = false; digest = Mentat_digest.derive ~domain parts }

let bubblewrap policy =
  let prefix =
    Backend.executable Backend.Bubblewrap :: Bubblewrap.arguments policy
  in
  { prefix; chdir = true; digest = Mentat_digest.derive ~domain prefix }

let prepare backend policy =
  match backend with
  | Backend.Seatbelt -> seatbelt policy
  | Backend.Bubblewrap -> bubblewrap policy

let digest t = t.digest

let wrap { prefix; chdir; _ } ~cwd argv =
  let prefix =
    if chdir then prefix @ [ "--chdir"; Lpath.Abs.to_string cwd; "--" ]
    else prefix
  in
  prefix @ argv
