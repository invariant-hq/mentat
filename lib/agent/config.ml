(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  model : Mentat_llm.Model.t;
  options : Mentat_llm.Request.Options.t;
  policy : Mentat_permission.Policy.t;
  review : Mentat_permission.Review_behavior.t;
  max_steps : int;
  compaction_pressure_tokens : int option;
  max_spawn_depth : int;
  max_exchanges : int;
}

let make ~model ?(options = Mentat_llm.Request.Options.default)
    ?(policy = Mentat_permission.Policy.default)
    ?(review = Mentat_permission.Review_behavior.Enforce) ?(max_steps = 500)
    ?compaction_pressure_tokens ?(max_spawn_depth = 1) ?(max_exchanges = 8) () =
  let positive name v =
    if v <= 0 then invalid_arg (Printf.sprintf "%s must be positive" name)
  in
  positive "max_steps" max_steps;
  Option.iter (positive "compaction_pressure_tokens") compaction_pressure_tokens;
  positive "max_spawn_depth" max_spawn_depth;
  positive "max_exchanges" max_exchanges;
  {
    model;
    options;
    policy;
    review;
    max_steps;
    compaction_pressure_tokens;
    max_spawn_depth;
    max_exchanges;
  }
