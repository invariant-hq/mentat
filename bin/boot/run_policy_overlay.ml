(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

let of_policy policy =
  let module P = Mentat_session.Metadata.Run_policy in
  let fail name e =
    Printf.sprintf "%s: %s" name (Mentat_config.Error.message e)
  in
  let set_text field name raw config =
    Result.map_error (fail name) (Mentat_config.set_text field raw config)
  in
  let steps =
    List.filter_map Fun.id
      [
        Option.map
          (set_text Mentat_config.Field.sandbox_mode "sandbox")
          (P.sandbox policy);
        (if P.require_sandbox policy then
           Some
             (fun config ->
               Result.map_error (fail "require_sandbox")
                 (Mentat_config.set Mentat_config.Field.sandbox_require
                    Mentat_sandbox.Requirement.Enforced_or_external config))
         else None);
        Option.map
          (fun n ->
            set_text Mentat_config.Field.run_max_steps "max_steps"
              (string_of_int n))
          (P.max_steps policy);
        Option.map (set_text Mentat_config.Field.model "model") (P.model policy);
        Option.map
          (set_text Mentat_config.Field.reasoning "reasoning")
          (P.reasoning policy);
        Option.map
          (set_text Mentat_config.Field.permission_unattended "unattended")
          (P.unattended policy);
        Option.map
          (fun on config ->
            Result.map_error (fail "project_instructions")
              (Mentat_config.set Mentat_config.Field.instructions_project on
                 config))
          (P.project_instructions policy);
      ]
  in
  if List.is_empty steps then Ok None
  else
    let* overlay =
      List.fold_left
        (fun acc step ->
          let* config = acc in
          step config)
        (Ok Mentat_config.empty) steps
    in
    Ok (Some overlay)
