(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Delegation = struct
  type t =
    | Parent_not_found of Mentat_session.Id.t
    | Edge_not_found of {
        parent : Mentat_session.Id.t;
        delegation : Mentat_session.Delegation.Id.t;
      }
    | Child_mismatch of {
        delegation : Mentat_session.Delegation.Id.t;
        expected : Mentat_session.Id.t;
        found : Mentat_session.Id.t;
      }
    | Cycle of Mentat_session.Id.t

  let message = function
    | Parent_not_found parent ->
        Format.asprintf "delegation parent is missing: %a" Mentat_session.Id.pp
          parent
    | Edge_not_found { parent; delegation } ->
        Format.asprintf "parent %a has no delegation %a" Mentat_session.Id.pp
          parent Mentat_session.Delegation.Id.pp delegation
    | Child_mismatch { delegation; expected; found } ->
        Format.asprintf "delegation %a names child %a, expected %a"
          Mentat_session.Delegation.Id.pp delegation Mentat_session.Id.pp found
          Mentat_session.Id.pp expected
    | Cycle session ->
        Format.asprintf "delegation lineage contains a cycle through %a"
          Mentat_session.Id.pp session

  let pp ppf error = Format.pp_print_string ppf (message error)
end

type t =
  | Busy of { owner : string option }
  | Not_found
  | Store of Mentat_diagnostic.t
  | Request of Mentat_llm.Request.Error.t
  | Session of Mentat_session.Error.t
  | Decision of Mentat_session.Decision.Resolve_error.t
  | Configuration of Mentat_diagnostic.t
  | Delegation of Delegation.t
  | Internal of Mentat_diagnostic.t
  | Shutting_down

let of_step = function
  | Mentat_agent_step.Error.Session e -> Session e
  | Mentat_agent_step.Error.Decision e -> Decision e
  | Mentat_agent_step.Error.Request e -> Request e
  | ( Mentat_agent_step.Error.No_active_turn
    | Mentat_agent_step.Error.No_pending_wait
    | Mentat_agent_step.Error.Call_not_pending _ ) as e ->
      Internal (Mentat_diagnostic.of_text (Mentat_agent_step.Error.message e))

let message = function
  | Busy { owner = Some owner } ->
      Printf.sprintf "session is busy: driven by %s" owner
  | Busy { owner = None } -> "session is busy: driven by another process"
  | Not_found -> "session document not found"
  | Store d -> Mentat_diagnostic.to_string d
  | Request e -> Mentat_llm.Request.Error.message e
  | Session e -> Mentat_session.Error.message e
  | Decision e -> Mentat_session.Decision.Resolve_error.message e
  | Configuration d -> Mentat_diagnostic.to_string d
  | Delegation e -> Delegation.message e
  | Internal d -> Mentat_diagnostic.to_string d
  | Shutting_down -> "the agent is shutting down"

let diagnostic = function
  | Configuration d | Internal d | Store d -> d
  | e -> Mentat_diagnostic.of_text (message e)

let pp ppf e = Format.pp_print_string ppf (message e)
