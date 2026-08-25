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
