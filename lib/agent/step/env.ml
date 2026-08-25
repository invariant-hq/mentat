(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  catalog : Catalog.t;
  sandbox : Mentat_sandbox.Identity.t;
  prelude : Mentat_llm.Request.Prelude.t;
  max_steps : int;
  denial_message : Mentat_permission.Policy.Denial.t -> string;
  compaction_pressure_tokens : int option;
  max_spawn_depth : int;
  max_exchanges : int;
  depth : int;
}

let default_denial_message _ = "Permission denied by policy."

let make ~catalog ~sandbox ?(prelude = Mentat_llm.Request.Prelude.empty)
    ?(denial_message = default_denial_message) ~max_steps
    ~compaction_pressure_tokens ~max_spawn_depth ~max_exchanges ~depth () =
  let invalid message =
    invalid_arg ("Mentat_agent_step.Env.make: " ^ message)
  in
  let require_positive name = function
    | Some value when value <= 0 ->
        invalid (Printf.sprintf "%s must be positive, got %d" name value)
    | Some _ | None -> ()
  in
  require_positive "max_steps" (Some max_steps);
  require_positive "compaction_pressure_tokens" compaction_pressure_tokens;
  require_positive "max_spawn_depth" (Some max_spawn_depth);
  require_positive "max_exchanges" (Some max_exchanges);
  if depth < 0 then
    invalid (Printf.sprintf "depth must be non-negative, got %d" depth);
  {
    catalog;
    sandbox;
    prelude;
    max_steps;
    denial_message;
    compaction_pressure_tokens;
    max_spawn_depth;
    max_exchanges;
    depth;
  }
