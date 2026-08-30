(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Claim_map = Map.Make (Mentat_session.Tool_claim.Id)
module Change_map = Map.Make (Change.Id)
module Revert_map = Map.Make (Revert_data.Id)
module Checkpoint_map = Map.Make (Checkpoint.Id)

type observation = {
  obs_turn : Mentat_session.Turn.Id.t;
  obs_claim : Mentat_session.Tool_claim.Id.t;
  obs_paths : Mentat_workspace.Path.t list;
}

type revert_record = {
  started : Revert_data.Started.t;
  settled : Revert_data.Settled.t option;
}

type t = {
  events : Event.t list;
  checkpoints : Checkpoint.t Checkpoint_map.t;
  claims : Mentat_session.Tool_claim.Id.t list;
  edits : Change.t list Claim_map.t;
      (* Per-claim change rows, stored newest-first so an Edit prepends its
         batch in O(batch) rather than copying the rows so far. Ledger order is
         materialized at the sole reader, [changes], which reverses on the way
         out; nothing else reads this map's order, so [finalize]/[unfinalize]
         leave it untouched and the append law's refold stays exact. *)
  ordinals : int Claim_map.t;
      (* The next expected apply ordinal per claim — the density law. *)
  claim_turns : Mentat_session.Turn.Id.t Claim_map.t;
      (* One turn per claim, pinned by the first referencing event. *)
  observed : Mentat_workspace.Path.Set.t Claim_map.t;
  observations : observation list;
  uncertains : observation list;
      (* Uncertain stopping targets, one path each, in ledger order — a
         revertability input alongside observations, kept apart so the
         [observed] projection stays exactly the Tool_observed yield. *)
  changes : (Change.t * Mentat_session.Turn.Id.t option) list;
  change_ids : Change.t Change_map.t;
  reverts : revert_record Revert_map.t;
  started_order : Revert_data.Id.t list;
  heads : Change.t Mentat_workspace.Path.Map.t;
}

module Error = struct
  type reason =
    | Duplicate_checkpoint of Checkpoint.Id.t
    | Invalid_ordinal of {
        claim : Mentat_session.Tool_claim.Id.t;
        ordinal : int;
        expected : int;
      }
    | Turn_conflict of Mentat_session.Tool_claim.Id.t
    | Duplicate_change of Change.Id.t
    | Invalid_transition of { path : Mentat_workspace.Path.t }
    | Dangling_checkpoint of Checkpoint.Id.t
    | Checkpoint_mismatch of Checkpoint.Id.t
    | Duplicate_revert of Revert_data.Id.t
    | Missing_revert_checkpoint of Revert_data.Id.t
    | Unknown_selected_change of Change.Id.t
    | Invalid_start of Revert_data.Id.t
    | Unmatched_settlement of Revert_data.Id.t
    | Settlement_mismatch of Revert_data.Id.t

  type t = { index : int; reason : reason }

  let reason_message = function
    | Duplicate_checkpoint id ->
        Format.asprintf "duplicate checkpoint %a" Checkpoint.Id.pp id
    | Invalid_ordinal { claim; ordinal; expected } ->
        Format.asprintf
          "edit event for claim %a carries ordinal %d, expected %d"
          Mentat_session.Tool_claim.Id.pp claim ordinal expected
    | Turn_conflict claim ->
        Format.asprintf "claim %a is already pinned to another turn"
          Mentat_session.Tool_claim.Id.pp claim
    | Duplicate_change id ->
        Format.asprintf "duplicate change %a" Change.Id.pp id
    | Invalid_transition { path } ->
        Format.asprintf "invalid image transition at %a"
          Mentat_workspace.Path.pp path
    | Dangling_checkpoint id ->
        Format.asprintf "edit references unknown checkpoint %a" Checkpoint.Id.pp
          id
    | Checkpoint_mismatch id ->
        Format.asprintf
          "checkpoint %a is not the turn's available before-turn-tools capture"
          Checkpoint.Id.pp id
    | Duplicate_revert id ->
        Format.asprintf "duplicate revert %a" Revert_data.Id.pp id
    | Missing_revert_checkpoint id ->
        Format.asprintf "revert %a has no preceding before-revert checkpoint"
          Revert_data.Id.pp id
    | Unknown_selected_change id ->
        Format.asprintf "revert selection references unknown change %a"
          Change.Id.pp id
    | Invalid_start id ->
        Format.asprintf
          "revert %a started with fields its history prefix cannot derive"
          Revert_data.Id.pp id
    | Unmatched_settlement id ->
        Format.asprintf "settlement for revert %a matches no unsettled start"
          Revert_data.Id.pp id
    | Settlement_mismatch id ->
        Format.asprintf
          "settlement for revert %a does not match its started targets"
          Revert_data.Id.pp id

  let message t =
    "event " ^ string_of_int t.index ^ ": " ^ reason_message t.reason

  let pp ppf t = Format.pp_print_string ppf (message t)
end

let empty =
  {
    events = [];
    checkpoints = Checkpoint_map.empty;
    claims = [];
    edits = Claim_map.empty;
    ordinals = Claim_map.empty;
    claim_turns = Claim_map.empty;
    observed = Claim_map.empty;
    observations = [];
    uncertains = [];
    changes = [];
    change_ids = Change_map.empty;
    reverts = Revert_map.empty;
    started_order = [];
    heads = Mentat_workspace.Path.Map.empty;
  }

let add_change st change turn =
  let id = Change.id change in
  if Change_map.mem id st.change_ids then Error (Error.Duplicate_change id)
  else
    match (Change.before change, Change.after change) with
    | Image.Missing, Image.Missing ->
        Error (Error.Invalid_transition { path = Change.path change })
    | (Image.Missing | Image.Text _), (Image.Missing | Image.Text _) ->
        Ok
          {
            st with
            change_ids = Change_map.add id change st.change_ids;
            changes = (change, turn) :: st.changes;
            heads =
              Mentat_workspace.Path.Map.add (Change.path change) change st.heads;
          }

let add_changes st changes turn =
  List.fold_left
    (fun acc change -> Result.bind acc (fun st -> add_change st change turn))
    (Ok st) changes

let note_claim st claim =
  if Claim_map.mem claim st.edits || Claim_map.mem claim st.observed then st
  else { st with claims = claim :: st.claims }

(* One turn per claim, pinned by the first referencing event: a ledger where
   one claim's evidence spans two turns is forged or corrupt. *)
let pin_turn st claim turn =
  match Claim_map.find_opt claim st.claim_turns with
  | Some pinned when not (Mentat_session.Turn.Id.equal pinned turn) ->
      Error (Error.Turn_conflict claim)
  | Some _ -> Ok st
  | None -> Ok { st with claim_turns = Claim_map.add claim turn st.claim_turns }

let settlement_matches (started : Revert_data.Started.t)
    (settled : Revert_data.Settled.t) =
  let target_paths =
    List.map
      (fun (target : Revert_data.Target.t) -> target.Revert_data.Target.path)
      started.Revert_data.Started.targets
  in
  let outcome_paths = List.map fst settled.Revert_data.Settled.outcomes in
  List.equal Mentat_workspace.Path.equal target_paths outcome_paths
  &&
  let confirmed =
    List.filter_map
      (fun (_, outcome) ->
        match (outcome : Revert_data.Settled.outcome) with
        | Revert_data.Settled.Confirmed id -> Some id
        | Revert_data.Settled.Ambiguous | Revert_data.Settled.Not_attempted ->
            None)
      settled.Revert_data.Settled.outcomes
  in
  let rows = List.map Change.id settled.Revert_data.Settled.changes in
  List.equal Change.Id.equal
    (List.sort Change.Id.compare confirmed)
    (List.sort Change.Id.compare rows)

(* Selection resolution over explicit ledger-order rows, shared between the
   finalized projections and the fold's revert-start validation (which runs
   at a prefix, in accumulator form). Restoration rows carry no turn, so a
   turns selection never resolves them. *)
let resolve_rows rows selection =
  match (selection : Revert_data.Selection.t) with
  | Revert_data.Selection.All -> List.map fst rows
  | Revert_data.Selection.Turns ids ->
      List.filter_map
        (fun (change, turn) ->
          match turn with
          | Some turn when List.exists (Mentat_session.Turn.Id.equal turn) ids
            ->
              Some change
          | Some _ | None -> None)
        rows
  | Revert_data.Selection.Changes ids ->
      List.filter_map
        (fun (change, _) ->
          if List.exists (Change.Id.equal (Change.id change)) ids then
            Some change
          else None)
        rows
  | Revert_data.Selection.Paths paths ->
      List.filter_map
        (fun (change, _) ->
          if
            List.exists (Mentat_workspace.Path.equal (Change.path change)) paths
          then Some change
          else None)
        rows

(* A decoded [Revert_started] must be one the planner could have minted at this
   prefix. Each netted entry is classified by
   superseded (its head moved past the net-after), contiguous, and overridden
   (its path in the frozen consent), and validated per cell. A trivial entry
   (not superseded, contiguous, not overridden) requires a target carrying the
   netted expected and restore; a merge entry (superseded, contiguous, not
   overridden) requires the expected to be the current head and trusts the
   restore image structurally — the merged bytes are no more replayable from
   history than an overridden expected is — and may lack a target only on a
   genuine M-equals-current drop; an override entry (not superseded,
   non-contiguous, overridden) requires the netted restore and trusts the
   plan-time expected, lacking a target only on a read-equals-restore drop. Every
   other combination is one the planner never mints and is rejected. Sources are
   always the netted sources; no target is orphaned; no older revert is
   unresolved; and the frozen consent is exactly the non-contiguous target paths.
   [st] is in accumulator form. *)
let start_is_valid st (started : Revert_data.Started.t) =
  Revert_map.for_all (fun _ record -> Option.is_some record.settled) st.reverts
  &&
  let rows = List.rev st.changes in
  match resolve_rows rows started.Revert_data.Started.selection with
  | [] -> false
  | resolved ->
      let entries = Change.net resolved in
      let entry_for path =
        List.find_opt
          (fun (entry : Change.Net.entry) ->
            Mentat_workspace.Path.equal entry.Change.Net.path path)
          entries
      in
      let target_for path =
        List.find_opt
          (fun (target : Revert_data.Target.t) ->
            Mentat_workspace.Path.equal target.Revert_data.Target.path path)
          started.Revert_data.Started.targets
      in
      let override_paths =
        match started.Revert_data.Started.override with
        | None -> []
        | Some override -> Revert_data.override_paths override
      in
      let sources_match (target : Revert_data.Target.t)
          (entry : Change.Net.entry) =
        List.equal Change.Id.equal target.Revert_data.Target.sources
          entry.Change.Net.sources
      in
      List.for_all
        (fun (entry : Change.Net.entry) ->
          let path = entry.Change.Net.path in
          match Mentat_workspace.Path.Map.find_opt path st.heads with
          | None -> false
          | Some head -> (
              let superseded =
                not (Image.equal (Change.after head) entry.Change.Net.after)
              in
              let contiguous = entry.Change.Net.contiguous in
              let overridden =
                List.exists (Mentat_workspace.Path.equal path) override_paths
              in
              match (superseded, contiguous, overridden) with
              | false, true, false -> (
                  match target_for path with
                  | Some target ->
                      Image.equal target.Revert_data.Target.expected
                        entry.Change.Net.after
                      && Image.equal target.Revert_data.Target.restore
                           entry.Change.Net.before
                      && sources_match target entry
                  | None -> false)
              | true, true, false -> (
                  match target_for path with
                  | Some target ->
                      Image.equal target.Revert_data.Target.expected
                        (Change.after head)
                      && sources_match target entry
                  | None -> true)
              | false, false, true -> (
                  match target_for path with
                  | Some target ->
                      Image.equal target.Revert_data.Target.restore
                        entry.Change.Net.before
                      && sources_match target entry
                  | None -> true)
              | _ -> false))
        entries
      && List.for_all
           (fun (target : Revert_data.Target.t) ->
             Option.is_some (entry_for target.Revert_data.Target.path))
           started.Revert_data.Started.targets
      &&
      let non_contiguous_targets =
        List.filter_map
          (fun (target : Revert_data.Target.t) ->
            match entry_for target.Revert_data.Target.path with
            | Some entry when not entry.Change.Net.contiguous ->
                Some target.Revert_data.Target.path
            | Some _ | None -> None)
          started.Revert_data.Started.targets
      in
      List.equal Mentat_workspace.Path.equal
        (List.sort Mentat_workspace.Path.compare non_contiguous_targets)
        override_paths

let first_unknown_selected_change st = function
  | Revert_data.Selection.Changes ids ->
      List.find_opt (fun id -> not (Change_map.mem id st.change_ids)) ids
  | Revert_data.Selection.All | Revert_data.Selection.Turns _
  | Revert_data.Selection.Paths _ ->
      None

let apply st event =
  match (event : Event.t) with
  | Event.Checkpoint checkpoint ->
      let id = Checkpoint.id checkpoint in
      if Checkpoint_map.mem id st.checkpoints then
        Error (Error.Duplicate_checkpoint id)
      else
        Ok
          {
            st with
            checkpoints = Checkpoint_map.add id checkpoint st.checkpoints;
          }
  | Event.Edit { turn; claim; ordinal; checkpoint; changes; uncertain } ->
      let expected =
        Option.value (Claim_map.find_opt claim st.ordinals) ~default:0
      in
      if ordinal <> expected then
        Error (Error.Invalid_ordinal { claim; ordinal; expected })
      else
        Result.bind (pin_turn st claim turn) (fun st ->
            let checkpoint_ok =
              match checkpoint with
              | None -> Ok ()
              | Some id -> (
                  match Checkpoint_map.find_opt id st.checkpoints with
                  | None -> Error (Error.Dangling_checkpoint id)
                  | Some cp -> (
                      match Checkpoint.boundary cp with
                      | Checkpoint.Before_turn_tools boundary_turn
                      | Checkpoint.After_recovery boundary_turn
                        when Mentat_session.Turn.Id.equal boundary_turn turn
                        -> (
                          (* An edit pins the turn's conservative capture: the
                             pre-tools one, or — for a recovered turn — the fresh
                             post-recovery one. *)
                          match Checkpoint.capture cp with
                          | Checkpoint.Capture.Available _ -> Ok ()
                          | Checkpoint.Capture.Degraded _ ->
                              Error (Error.Checkpoint_mismatch id))
                      | Checkpoint.Before_turn_tools _
                      | Checkpoint.After_recovery _ | Checkpoint.After_turn _
                      | Checkpoint.Before_revert _ ->
                          Error (Error.Checkpoint_mismatch id)))
            in
            Result.bind checkpoint_ok (fun () ->
                let st = note_claim st claim in
                let rev_recorded =
                  Option.value (Claim_map.find_opt claim st.edits) ~default:[]
                in
                let st =
                  {
                    st with
                    edits =
                      Claim_map.add claim
                        (List.rev_append changes rev_recorded)
                        st.edits;
                    ordinals = Claim_map.add claim (ordinal + 1) st.ordinals;
                  }
                in
                let st =
                  match uncertain with
                  | None -> st
                  | Some path ->
                      {
                        st with
                        uncertains =
                          {
                            obs_turn = turn;
                            obs_claim = claim;
                            obs_paths = [ path ];
                          }
                          :: st.uncertains;
                      }
                in
                add_changes st changes (Some turn)))
  | Event.Tool_observed { turn; claim; paths } ->
      Result.bind (pin_turn st claim turn) (fun st ->
          let st = note_claim st claim in
          let set =
            Option.value
              (Claim_map.find_opt claim st.observed)
              ~default:Mentat_workspace.Path.Set.empty
          in
          let set =
            List.fold_left
              (fun set path -> Mentat_workspace.Path.Set.add path set)
              set paths
          in
          Ok
            {
              st with
              observed = Claim_map.add claim set st.observed;
              observations =
                { obs_turn = turn; obs_claim = claim; obs_paths = paths }
                :: st.observations;
            })
  | Event.Revert_started started -> (
      let id = started.Revert_data.Started.id in
      if Revert_map.mem id st.reverts then Error (Error.Duplicate_revert id)
      else
        match
          first_unknown_selected_change st started.Revert_data.Started.selection
        with
        | Some selected -> Error (Error.Unknown_selected_change selected)
        | None ->
            if not (start_is_valid st started) then
              Error (Error.Invalid_start id)
            else if
              not
                (Checkpoint_map.mem
                   (Checkpoint.id_of_boundary (Checkpoint.Before_revert id))
                   st.checkpoints)
            then Error (Error.Missing_revert_checkpoint id)
            else
              Ok
                {
                  st with
                  reverts =
                    Revert_map.add id { started; settled = None } st.reverts;
                  started_order = id :: st.started_order;
                })
  | Event.Revert_settled settled -> (
      let id = settled.Revert_data.Settled.revert in
      match Revert_map.find_opt id st.reverts with
      | None | Some { settled = Some _; _ } ->
          Error (Error.Unmatched_settlement id)
      | Some { started; settled = None } ->
          if not (settlement_matches started settled) then
            Error (Error.Settlement_mismatch id)
          else
            Result.bind
              (add_changes st settled.Revert_data.Settled.changes None)
              (fun st ->
                Ok
                  {
                    st with
                    reverts =
                      Revert_map.add id
                        { started; settled = Some settled }
                        st.reverts;
                  }))

let finalize st events =
  {
    st with
    events;
    claims = List.rev st.claims;
    observations = List.rev st.observations;
    uncertains = List.rev st.uncertains;
    changes = List.rev st.changes;
    started_order = List.rev st.started_order;
  }

(* Inverse of [finalize] up to the [events] field: each reversed list is an
   involution, so a finalized state re-enters accumulator form exactly. The
   [edits] map is stored newest-first throughout — neither direction touches it.
   [apply] reads the maps and, for revert-start validation, the reversed
   [changes] list — both agree between the incremental fold and a full refold. *)
let unfinalize st =
  {
    st with
    claims = List.rev st.claims;
    observations = List.rev st.observations;
    uncertains = List.rev st.uncertains;
    changes = List.rev st.changes;
    started_order = List.rev st.started_order;
  }

let fold_events ~index st ~events batch =
  let rec fold index st = function
    | [] -> Ok (finalize st events)
    | event :: rest -> (
        match apply st event with
        | Ok st -> fold (index + 1) st rest
        | Error reason -> Error { Error.index; reason })
  in
  fold index st batch

let of_events events = fold_events ~index:0 empty ~events events

let append t batch =
  let events = t.events @ batch in
  fold_events ~index:(List.length t.events) (unfinalize t) ~events batch

let events t = t.events
let claims t = t.claims

let changes t ~claim =
  (* The map stores rows newest-first; ledger order is materialized here. *)
  List.rev (Option.value (Claim_map.find_opt claim t.edits) ~default:[])

let change t id = Change_map.find_opt id t.change_ids

let observed t ~claim =
  match Claim_map.find_opt claim t.observed with
  | None -> []
  | Some set -> Mentat_workspace.Path.Set.elements set

let checkpoint_at t boundary =
  Checkpoint_map.find_opt (Checkpoint.id_of_boundary boundary) t.checkpoints

(* The prefix of a validated ledger is itself valid: every cross-event
   invariant is an ordering or uniqueness fact, so re-applying the prefix
   cannot fail and the fold trusts its own invariant. *)
let at_claim t ~claim =
  let refs event =
    match (event : Event.t) with
    | Event.Edit { claim = c; _ } | Event.Tool_observed { claim = c; _ } ->
        Mentat_session.Tool_claim.Id.equal c claim
    | Event.Checkpoint _ | Event.Revert_started _ | Event.Revert_settled _ ->
        false
  in
  let _, prefix =
    List.fold_left
      (fun (rev_events, prefix) event ->
        let rev_events = event :: rev_events in
        (rev_events, if refs event then Some rev_events else prefix))
      ([], None) t.events
  in
  match prefix with
  | None -> None
  | Some rev_prefix ->
      let events = List.rev rev_prefix in
      let st =
        List.fold_left
          (fun st event ->
            match apply st event with Ok st -> st | Error _ -> assert false)
          empty events
      in
      Some (finalize st events)

(* The turns an event references — the correlation coordinates the store joins
   against a document, so a prefix free of dropped-turn references is exactly one
   that correlates against a document holding only the kept turns. *)
let turn_refs event =
  match (event : Event.t) with
  | Event.Edit { turn; _ } | Event.Tool_observed { turn; _ } -> [ turn ]
  | Event.Checkpoint checkpoint -> (
      match Checkpoint.boundary checkpoint with
      | Checkpoint.Before_turn_tools turn
      | Checkpoint.After_recovery turn
      | Checkpoint.After_turn turn ->
          [ turn ]
      | Checkpoint.Before_revert _ -> [])
  | Event.Revert_started started -> (
      match started.Revert_data.Started.selection with
      | Revert_data.Selection.Turns turns -> turns
      | Revert_data.Selection.All | Revert_data.Selection.Changes _
      | Revert_data.Selection.Paths _ ->
          [])
  | Event.Revert_settled _ -> []

let prefix_for_turns t ~keep =
  let rec go acc = function
    | [] -> List.rev acc
    | event :: rest ->
        if List.for_all keep (turn_refs event) then go (event :: acc) rest
        else List.rev acc
  in
  go [] t.events

(* Internal: selection resolution in ledger order, shared with
   [Revert.prepare]. *)
let resolve t selection = resolve_rows t.changes selection
let net t selection = Change.net (resolve t selection)

(* Only an editing turn qualifies: observations and reverts carry no turn. *)
let latest_edit_turn t =
  List.fold_left
    (fun acc -> function Event.Edit { turn; _ } -> Some turn | _ -> acc)
    None t.events

(* Internal: the ledger's last recorded change for a path. *)
let head t path = Mentat_workspace.Path.Map.find_opt path t.heads

let unresolved_reverts t =
  List.filter_map
    (fun id ->
      match Revert_map.find_opt id t.reverts with
      | Some { started; settled = None } -> Some started
      | Some { settled = Some _; _ } | None -> None)
    t.started_order

let settled_revert t id =
  match Revert_map.find_opt id t.reverts with
  | Some { settled; _ } -> settled
  | None -> None

let revertability t selection =
  let resolved = resolve t selection in
  let entries = Change.net resolved in
  let superseded =
    List.filter_map
      (fun (entry : Change.Net.entry) ->
        match head t entry.Change.Net.path with
        | Some head
          when not (Image.equal (Change.after head) entry.Change.Net.after) ->
            Some
              (Revertability.Superseded
                 { path = entry.Change.Net.path; by = Change.id head })
        | Some _ | None -> None)
      entries
  in
  let non_contiguous =
    List.filter_map
      (fun (entry : Change.Net.entry) ->
        if entry.Change.Net.contiguous then None
        else
          Some (Revertability.Non_contiguous { path = entry.Change.Net.path }))
      entries
  in
  let resolved_paths =
    List.fold_left
      (fun set change -> Mentat_workspace.Path.Set.add (Change.path change) set)
      Mentat_workspace.Path.Set.empty resolved
  in
  let in_scope observation =
    match (selection : Revert_data.Selection.t) with
    | Revert_data.Selection.All -> true
    | Revert_data.Selection.Turns ids ->
        List.exists (Mentat_session.Turn.Id.equal observation.obs_turn) ids
    | Revert_data.Selection.Paths paths ->
        (* Membership in the selection's own paths, not just the resolved
           intersection: a paths scope whose only activity is observed must
           not answer a vacuous [Available]. *)
        List.exists
          (fun path -> List.exists (Mentat_workspace.Path.equal path) paths)
          observation.obs_paths
    | Revert_data.Selection.Changes _ -> false
  in
  let window_in_scope observation =
    in_scope observation
    || List.exists
         (fun path -> Mentat_workspace.Path.Set.mem path resolved_paths)
         observation.obs_paths
  in
  let observed_claims =
    List.filter_map
      (fun observation ->
        if window_in_scope observation then Some observation.obs_claim else None)
      t.observations
  in
  let observed =
    let rec dedup seen = function
      | [] -> []
      | claim :: rest ->
          if List.exists (Mentat_session.Tool_claim.Id.equal claim) seen then
            dedup seen rest
          else Revertability.Observed { claim } :: dedup (claim :: seen) rest
    in
    dedup [] observed_claims
  in
  (* An uncertain stopping target enters the answer through the same window
     rules as an observation: the recorded apply may or may not have changed
     the path, so the evidence cannot prove what a revert of that span
     restores. Unlike an observation, the reason keeps the per-path causal
     tie. *)
  let uncertain =
    List.filter_map
      (fun window ->
        if window_in_scope window then
          match window.obs_paths with
          | [ path ] ->
              Some (Revertability.Uncertain { claim = window.obs_claim; path })
          | _ -> assert false (* uncertain windows carry exactly one path *)
        else None)
      t.uncertains
  in
  (* A selection is vacuous only when it resolves no change AND contains no
     observation or uncertain target: an observed-only or uncertain-only scope
     answers [Incomplete] even though nothing nets, so an opaque writer's or
     unconfirmed write's span never reads as revertable. *)
  match (resolved, observed, uncertain) with
  | [], [], [] -> Revertability.Available
  | _, _, _ -> (
      let unresolved =
        List.map
          (fun (started : Revert_data.Started.t) ->
            Revertability.Unresolved_revert started.Revert_data.Started.id)
          (unresolved_reverts t)
      in
      let reasons =
        superseded @ non_contiguous @ observed @ uncertain @ unresolved
      in
      match (reasons, superseded) with
      | [], _ -> Revertability.Available
      | _ :: _, _ :: _ -> Revertability.Unavailable reasons
      | _ :: _, [] -> Revertability.Incomplete reasons)
