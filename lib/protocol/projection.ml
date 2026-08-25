(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Settlement evidence: the claim's own exact change rows, its opaque observed
   paths, run-cumulative totals for the claim's turn as of this settlement, and
   the settlement-time revertability of exactly those. The revertability is
   computed against the claim's mutation-ledger prefix ([State.at_claim]) — the
   ledger through the claim's last event, never the full replayed ledger —
   which is what keeps live and replayed facts' durable projections identical
   when later changes supersede the claim's. The exact rows
   select revertability precisely; an observed-only claim selects it by its
   observed paths, which the owner answers [Incomplete]. *)
let evidence mutation ~cumulative ~changes ~claim =
  let observed = Mentat_mutation.State.observed mutation ~claim in
  match (changes, observed) with
  | [], [] -> None
  | _ ->
      let totals = Mentat_mutation.Change.of_changes cumulative in
      (* One of [changes]/[observed] is non-empty here (the [[], []] case
         returned [None] above), so neither constructor raises. *)
      let selection =
        match changes with
        | _ :: _ ->
            Mentat_mutation.Revert.Selection.changes
              (List.map Mentat_mutation.Change.id changes)
        | [] -> Mentat_mutation.Revert.Selection.paths observed
      in
      let revertability =
        match Mentat_mutation.State.at_claim mutation ~claim with
        | Some prefix -> Mentat_mutation.State.revertability prefix selection
        | None ->
            assert false (* the claim is referenced: an edit or observation. *)
      in
      Some { Fact.changes; observed; totals; revertability }

let settled_tool mutation ~emit rev_cumulative settlement =
  let claim = Mentat_session.Tool_claim.Settled.id settlement in
  let changes = Mentat_mutation.State.changes mutation ~claim in
  let rev_cumulative = List.rev_append changes rev_cumulative in
  let fact =
    if not emit then None
    else
      let evidence () =
        evidence mutation ~cumulative:(List.rev rev_cumulative) ~changes ~claim
      in
      Some
        (match Mentat_session.Tool_claim.Settled.outcome settlement with
        | Mentat_session.Tool_claim.Settled.Prepared prepared ->
            Fact.Tool_prepared
              {
                claim;
                description = Mentat_tool.Prepared.description prepared;
                requests = Mentat_tool.Prepared.requests prepared;
              }
        | Mentat_session.Tool_claim.Settled.Returned result ->
            Fact.Tool_returned { claim; result; mutation = evidence () }
        | Mentat_session.Tool_claim.Settled.Ambiguous ->
            Fact.Tool_ambiguous { claim; mutation = evidence () })
  in
  (rev_cumulative, fact)

(* The undo boundary fact: the durable update plus the presentation fields the
   seam renders. The crossed turns are every turn from the anchor to the latest —
   while armed no turn starts, so the anchor's suffix of the turn order is the
   whole crossed range regardless of which armed event this is. [dropped_turns]
   counts the user turns in that range (one per [/undo] press); [files] sums the
   crossed turns' recorded change rows per path, in first-seen order — the same
   recorded-count source tool settlements' totals use, so no blob resolution is
   needed at the projector. A [Released] update carries no count and no files. *)
let undo_files mutation selection =
  let changes = Mentat_mutation.State.resolve mutation selection in
  let rec merge acc = function
    | [] -> List.rev acc
    | change :: rest ->
        let path = Mentat_mutation.Change.path change in
        let additions = Mentat_mutation.Change.additions change in
        let deletions = Mentat_mutation.Change.deletions change in
        let acc =
          match
            List.partition
              (fun (file : Fact.undo_file) ->
                Mentat_workspace.Path.equal file.Fact.path path)
              acc
          with
          | [ file ], others ->
              {
                file with
                Fact.additions = file.Fact.additions + additions;
                Fact.deletions = file.Fact.deletions + deletions;
              }
              :: others
          | _ -> { Fact.path; Fact.additions; Fact.deletions } :: acc
        in
        merge acc rest
  in
  (* [merge] prepends, so the accumulator is newest-first; reverse once at the
     end restores first-seen path order. *)
  List.rev (merge [] changes)

let undo_fact ~mutation ~session_state update =
  match (update : Mentat_session.Undo.Update.t) with
  | Mentat_session.Undo.Update.Released ->
      Fact.Undo { update; dropped_turns = 0; files = [] }
  | Mentat_session.Undo.Update.Armed { anchor; _ } ->
      let ordered = Mentat_session.State.turns session_state in
      let crossed =
        let rec from_anchor = function
          | [] -> []
          | turn :: rest ->
              if
                Mentat_session.Turn.Id.equal
                  (Mentat_session.Turn.id turn)
                  anchor
              then turn :: rest
              else from_anchor rest
        in
        from_anchor ordered
      in
      let dropped_turns =
        List.length
          (List.filter
             (fun turn ->
               Option.is_some
                 (Mentat_session.State.turn_first_message_index
                    (Mentat_session.Turn.id turn)
                    session_state))
             crossed)
      in
      let files =
        match List.map Mentat_session.Turn.id crossed with
        | [] -> []
        | ids ->
            undo_files mutation (Mentat_mutation.Revert.Selection.turns ids)
      in
      Fact.Undo { update; dropped_turns; files }

(* Project one journal event at [seq] against the carried fold state: the
   active turn's settled change rows ([rev_cumulative], newest first) and
   whether the fold is inside a compaction turn ([in_compaction]). [emit] is the
   suffix gate — with it false the fact is withheld while the carries still
   advance ([rev_cumulative] gets its [rev_append] regardless), so a suffix
   projects identically to the matching suffix of the whole. Returns the
   advanced carries, [emits] — whether the event projects a fact at all,
   gate-independent, the signal [after] needs to prove [from] named a
   fact-emitting event without computing its evidence — and the position-tagged
   fact when the gate is open and the event is not suppressed by an enclosing
   compaction turn. This is the projector's single per-event body, shared by the
   one-shot [scan] and the resumable [advance] so both fold identically. *)
let project_event ~session_id ~session_state ~mutation ~emit ~seq
    ~rev_cumulative ~in_compaction event =
  let mk fact = if emit then Some fact else None in
  let rev_cumulative, emits, fact =
    match (event : Mentat_session.Event.t) with
    | Mentat_session.Event.Turn_started turn ->
        ([], true, mk (Fact.Turn_started turn))
    | Mentat_session.Event.Interrupt_requested _ ->
        (* Recovery-only: the durable interrupt request projects to
           nothing; its consequences project as settlements. *)
        (rev_cumulative, false, None)
    | Mentat_session.Event.Turn_finished { turn; outcome } ->
        (rev_cumulative, true, mk (Fact.Turn_settled { turn; outcome }))
    | Mentat_session.Event.Message_appended message ->
        (rev_cumulative, true, mk (Fact.Turn_message message))
    | Mentat_session.Event.Provider_requested _ ->
        (* Recovery-only: the provider-request claim projects to nothing. *)
        (rev_cumulative, false, None)
    | Mentat_session.Event.Provider_settled settlement -> (
        match Mentat_session.Provider_request.Settled.outcome settlement with
        | Mentat_session.Provider_request.Settled.Responded response ->
            (rev_cumulative, true, mk (Fact.Turn_assistant response))
        | Mentat_session.Provider_request.Settled.Interrupted { text; _ } ->
            (rev_cumulative, true, mk (Fact.Turn_assistant_interrupted { text }))
        | Mentat_session.Provider_request.Settled.Failed error ->
            let claim = Mentat_session.Provider_request.Settled.id settlement in
            ( rev_cumulative,
              true,
              mk (Fact.Turn_provider_failed { claim; error }) )
        | Mentat_session.Provider_request.Settled.Ambiguous ->
            (* Recovery-only: nothing was recorded; the turn's
               interrupted terminal outcome projects instead. *)
            (rev_cumulative, false, None))
    | Mentat_session.Event.Tool_claimed claim ->
        (rev_cumulative, true, mk (Fact.Tool_started claim))
    | Mentat_session.Event.Tool_settled settlement ->
        let rev_cumulative, fact =
          settled_tool mutation ~emit rev_cumulative settlement
        in
        (rev_cumulative, true, fact)
    | Mentat_session.Event.Decision_requested request ->
        (rev_cumulative, true, mk (Fact.Decision_requested request))
    | Mentat_session.Event.Decision_resolved resolution ->
        (rev_cumulative, true, mk (Fact.Decision_resolved resolution))
    | Mentat_session.Event.Compaction_installed compaction ->
        (rev_cumulative, true, mk (Fact.Compaction compaction))
    | Mentat_session.Event.Tasks_replaced board ->
        (rev_cumulative, true, mk (Fact.Journal_task_board board))
    | Mentat_session.Event.Delegation_recorded edge ->
        (rev_cumulative, true, mk (Fact.Journal_delegation edge))
    | Mentat_session.Event.Delegations_detached ->
        (* Branch-reset authority bookkeeping is not a frontend fact.
           Historical delegation facts already projected from the copied
           prefix remain visible. *)
        (rev_cumulative, false, None)
    | Mentat_session.Event.Queue_updated update ->
        (rev_cumulative, true, mk (Fact.Journal_queue update))
    | Mentat_session.Event.Workspace_notice notice ->
        (rev_cumulative, true, mk (Fact.Workspace_notice notice))
    | Mentat_session.Event.Undo_updated update ->
        (rev_cumulative, true, mk (undo_fact ~mutation ~session_state update))
  in
  (* Enter a compaction turn on its [Turn_started], leave on its [Turn_finished];
     while inside, suppress every projection except the [Compaction] fact the
     turn exists to install. A manual compaction turn ([Origin.Compaction]) is
     transparent on the feed — it reads exactly like an automatic one. These
     turns never nest and always settle. *)
  let in_compaction, suppress =
    match (event : Mentat_session.Event.t) with
    | Mentat_session.Event.Turn_started turn
      when Mentat_session.Turn.Origin.equal
             (Mentat_session.Turn.origin turn)
             Mentat_session.Turn.Origin.Compaction ->
        (true, true)
    | Mentat_session.Event.Turn_finished _ when in_compaction -> (false, true)
    | Mentat_session.Event.Compaction_installed _ -> (in_compaction, false)
    | _ -> (in_compaction, in_compaction)
  in
  let emits, fact = if suppress then (false, None) else (emits, fact) in
  let entry =
    Option.map (fun fact -> (Position.make ~session:session_id ~seq, fact)) fact
  in
  (rev_cumulative, in_compaction, emits, entry)

(* One pass over the whole journal with the emit gate open from [from], carrying
   the per-event fold state through [project_event]. Serves [after]: the one-shot
   suffix projector and its membership proof. *)
let scan ~from ~session ~mutation =
  let session_id = Mentat_session.id session in
  let session_state = Mentat_session.state session in
  let from_seq = match from with None -> 0 | Some seq -> seq + 1 in
  let member_seq = match from with None -> -1 | Some seq -> seq in
  let rec loop seq rev_cumulative in_compaction member acc = function
    | [] -> (List.rev acc, member)
    | event :: rest ->
        let emit = seq >= from_seq in
        let rev_cumulative, in_compaction, emits, entry =
          project_event ~session_id ~session_state ~mutation ~emit ~seq
            ~rev_cumulative ~in_compaction event
        in
        let member = member || (emits && Int.equal seq member_seq) in
        let acc = match entry with Some e -> e :: acc | None -> acc in
        loop (seq + 1) rev_cumulative in_compaction member acc rest
  in
  loop 0 [] false false [] (Mentat_session.events session)

type resume = {
  consumed : int;
  rev_cumulative : Mentat_mutation.Change.t list;
  in_compaction : bool;
}

let start = { consumed = 0; rev_cumulative = []; in_compaction = false }
let consumed resume = resume.consumed

let advance resume ~session ~mutation ~delta =
  let session_id = Mentat_session.id session in
  let session_state = Mentat_session.state session in
  let rec loop seq rev_cumulative in_compaction acc = function
    | [] -> ({ consumed = seq; rev_cumulative; in_compaction }, List.rev acc)
    | event :: rest ->
        let rev_cumulative, in_compaction, _emits, entry =
          project_event ~session_id ~session_state ~mutation ~emit:true ~seq
            ~rev_cumulative ~in_compaction event
        in
        let acc = match entry with Some e -> e :: acc | None -> acc in
        loop (seq + 1) rev_cumulative in_compaction acc rest
  in
  loop resume.consumed resume.rev_cumulative resume.in_compaction [] delta

let all ~session ~mutation =
  snd (advance start ~session ~mutation ~delta:(Mentat_session.events session))

let after position ~session ~mutation =
  let session_id = Mentat_session.id session in
  let actual = Position.session position in
  if not (Mentat_session.Id.equal actual session_id) then
    Error (Position.Invalid.Foreign_session { expected = session_id; actual })
  else
    let facts, member =
      scan ~from:(Some (Position.seq position)) ~session ~mutation
    in
    if member then Ok facts else Error (Position.Invalid.Not_in_feed position)
