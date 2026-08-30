(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Id = Revert_data.Id
module Selection = Revert_data.Selection
module Evidence = Revert_data.Evidence
module Override = Revert_data.Override
module Problem = Revert_data.Problem
module Target = Revert_data.Target
module Started = Revert_data.Started
module Plan = Revert_data.Plan
module Edit_failure = Revert_data.Edit_failure
module Settled = Revert_data.Settled

let invalid fn message = invalid_arg' "Mentat_mutation.Revert" fn message

module Scope = struct
  type t = Latest | Change of Change.Id.t | Path of Mentat_workspace.Path.t

  let resolve state = function
    | Latest ->
        Option.map
          (fun turn -> Selection.turns [ turn ])
          (State.latest_edit_turn state)
    | Change id -> Some (Selection.changes [ id ])
    | Path path -> Some (Selection.paths [ path ])

  let jsont =
    let latest_case =
      Jsont.Object.map ~kind:"latest scope" Latest
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "latest" ~dec:Fun.id
    in
    let change_case =
      Jsont.Object.map ~kind:"change scope" (fun id -> Change id)
      |> Jsont.Object.mem "change" Change.Id.jsont ~enc:(function
        | Change id -> id
        | _ -> invalid "Scope.jsont" "change case")
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "change" ~dec:Fun.id
    in
    let path_case =
      Jsont.Object.map ~kind:"path scope" (fun p -> Path p)
      |> Jsont.Object.mem "path" Mentat_workspace.Path.jsont ~enc:(function
        | Path p -> p
        | _ -> invalid "Scope.jsont" "path case")
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "path" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make [ latest_case; change_case; path_case ]
    in
    let enc_case = function
      | Latest -> Jsont.Object.Case.value latest_case Latest
      | Change _ as s -> Jsont.Object.Case.value change_case s
      | Path _ as s -> Jsont.Object.Case.value path_case s
    in
    Jsont.Object.map ~kind:"revert scope" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Outcome = struct
  type t = Applied of Settled.t | Nothing_to_revert | Refused of string list

  let jsont =
    let applied_case =
      Jsont.Object.map ~kind:"applied outcome" (fun s -> Applied s)
      |> Jsont.Object.mem "settled" Settled.jsont ~enc:(function
        | Applied s -> s
        | _ -> invalid "Outcome.jsont" "applied case")
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "applied" ~dec:Fun.id
    in
    let nothing_case =
      Jsont.Object.map ~kind:"nothing outcome" Nothing_to_revert
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "nothing_to_revert" ~dec:Fun.id
    in
    let refused_case =
      Jsont.Object.map ~kind:"refused outcome" (fun ms -> Refused ms)
      |> Jsont.Object.mem "problems" (Jsont.list Jsont.string) ~enc:(function
        | Refused ms -> ms
        | _ -> invalid "Outcome.jsont" "refused case")
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "refused" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ applied_case; nothing_case; refused_case ]
    in
    let enc_case = function
      | Applied _ as o -> Jsont.Object.Case.value applied_case o
      | Nothing_to_revert ->
          Jsont.Object.Case.value nothing_case Nothing_to_revert
      | Refused _ as o -> Jsont.Object.Case.value refused_case o
    in
    Jsont.Object.map ~kind:"revert outcome" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let prepare ?(merge = true) ?override ~id ~evidence state selection =
  let unresolved =
    List.map
      (fun (started : Started.t) ->
        Problem.Unresolved_revert started.Started.id)
      (State.unresolved_reverts state)
  in
  match State.resolve state selection with
  | [] -> Error (unresolved @ [ Problem.Nothing_to_revert ])
  | resolved -> (
      let entries = Change.net resolved in
      let override_paths =
        match override with
        | None -> Mentat_workspace.Path.Set.empty
        | Some o ->
            Mentat_workspace.Path.Set.of_list (Revert_data.override_paths o)
      in
      let resolve_image_blob = function
        | Image.Missing -> Ok ""
        | Image.Text reference -> (
            match Revert_data.evidence_find_blob evidence reference with
            | Some bytes -> Ok bytes
            | None -> Error reference)
      in
      (* Rung 2: a superseded selection whose current read is
         still the recorded head is not refused but merged — [base] is the
         selection's net-after, [ours] the current file carrying the later
         change, [theirs] the net-before. A clean merge yields a target that
         rewrites the current file to the merged image; a conflict, a missing
         base blob, an unrecorded writer, a non-contiguous entry, or an override
         all fall through to the existing logic. Gated by [merge]; when off, the
         superseded arm refuses byte-identically. *)
      let try_merge ~overridden (entry : Change.Net.entry) =
        let path = entry.Change.Net.path in
        match State.head state path with
        | Some head
          when (not (Image.equal (Change.after head) entry.Change.Net.after))
               && entry.Change.Net.contiguous && not overridden -> (
            match Revert_data.evidence_read evidence path with
            | Some
                ((Mentat_edit.Observed.Text _ | Mentat_edit.Observed.Missing) as
                 observed) -> (
                let current =
                  match observed with
                  | Mentat_edit.Observed.Text contents ->
                      Image.Text
                        (Mentat_digest.Content_ref.of_contents contents)
                  | Mentat_edit.Observed.Missing -> Image.Missing
                  | Mentat_edit.Observed.Other -> assert false
                in
                if not (Image.equal current (Change.after head)) then `Skip
                else
                  match resolve_image_blob entry.Change.Net.after with
                  | Error reference ->
                      `Problem
                        [ Problem.Missing_blob { path; content = reference } ]
                  | Ok base -> (
                      match resolve_image_blob entry.Change.Net.before with
                      | Error _ -> `Skip
                      | Ok theirs -> (
                          let ours =
                            match observed with
                            | Mentat_edit.Observed.Text contents -> contents
                            | Mentat_edit.Observed.Missing -> ""
                            | Mentat_edit.Observed.Other -> assert false
                          in
                          match Textdiff.Merge.v ~base ~ours ~theirs () with
                          | Some merged when Textdiff.Merge.is_clean merged -> (
                              match Textdiff.Merge.resolved merged with
                              | None -> assert false
                              | Some text ->
                                  let restore =
                                    match entry.Change.Net.before with
                                    | Image.Missing when String.equal text "" ->
                                        Image.Missing
                                    | Image.Missing | Image.Text _ ->
                                        Image.Text
                                          (Mentat_digest.Content_ref.of_contents
                                             text)
                                  in
                                  if Image.equal current restore then `Drop
                                  else
                                    let target =
                                      Revert_data.target ~path ~expected:current
                                        ~restore
                                        ~sources:entry.Change.Net.sources
                                    in
                                    let blob =
                                      match restore with
                                      | Image.Text reference ->
                                          Some (reference, text)
                                      | Image.Missing -> None
                                    in
                                    `Ok (target, blob))
                          | Some merged ->
                              `Problem
                                [ Problem.Conflict { path; merge = merged } ]
                          | None -> `Skip)))
            | Some Mentat_edit.Observed.Other | None -> `Skip)
        | Some _ | None -> `Skip
      in
      let rev_problems, rev_targets, rev_merge_blobs =
        List.fold_left
          (fun (rev_problems, rev_targets, rev_merge_blobs)
               (entry : Change.Net.entry) ->
            let path = entry.Change.Net.path in
            let overridden =
              Mentat_workspace.Path.Set.mem path override_paths
            in
            match if merge then try_merge ~overridden entry else `Skip with
            | `Ok (target, blob) ->
                ( rev_problems,
                  target :: rev_targets,
                  match blob with
                  | Some blob -> blob :: rev_merge_blobs
                  | None -> rev_merge_blobs )
            | `Drop -> (rev_problems, rev_targets, rev_merge_blobs)
            | `Problem problems ->
                ( List.rev_append problems rev_problems,
                  rev_targets,
                  rev_merge_blobs )
            | `Skip -> (
                let unmatched =
                  if entry.Change.Net.contiguous && overridden then
                    [ Problem.Unmatched_override { path } ]
                  else []
                in
                let superseded =
                  match State.head state path with
                  | Some head
                    when not
                           (Image.equal (Change.after head)
                              entry.Change.Net.after) ->
                      [ Problem.Superseded { path; by = Change.id head } ]
                  | Some _ | None -> []
                in
                let needs_override =
                  if (not entry.Change.Net.contiguous) && not overridden then
                    [ Problem.Needs_override { path } ]
                  else []
                in
                let read_problems, current =
                  match Revert_data.evidence_read evidence path with
                  | None -> ([ Problem.Missing_read path ], None)
                  | Some Mentat_edit.Observed.Other ->
                      ([ Problem.Unreadable { path } ], None)
                  | Some current_state ->
                      let image =
                        match current_state with
                        | Mentat_edit.Observed.Missing -> Image.Missing
                        | Mentat_edit.Observed.Text contents ->
                            Image.Text
                              (Mentat_digest.Content_ref.of_contents contents)
                        | Mentat_edit.Observed.Other -> assert false
                      in
                      if
                        entry.Change.Net.contiguous
                        && not (Image.equal image entry.Change.Net.after)
                      then
                        ( [
                            Problem.Stale
                              {
                                path;
                                expected = entry.Change.Net.after;
                                actual = image;
                              };
                          ],
                          None )
                      else ([], Some image)
                in
                let missing_blob =
                  match entry.Change.Net.before with
                  | Image.Text content
                    when Option.is_none
                           (Revert_data.evidence_find_blob evidence content) ->
                      [ Problem.Missing_blob { path; content } ]
                  | Image.Missing | Image.Text _ -> []
                in
                let problems =
                  unmatched @ superseded @ needs_override @ read_problems
                  @ missing_blob
                in
                match (problems, current) with
                | [], Some current_image ->
                    if Image.equal current_image entry.Change.Net.before then
                      (* The plan-time read already equals the restore image:
                     nothing would change for this path and nothing is
                     lost, so it is dropped rather than lowered to a no-op
                     edit. Reachable only through an override. *)
                      (rev_problems, rev_targets, rev_merge_blobs)
                    else
                      let target =
                        Revert_data.target ~path ~expected:current_image
                          ~restore:entry.Change.Net.before
                          ~sources:entry.Change.Net.sources
                      in
                      (rev_problems, target :: rev_targets, rev_merge_blobs)
                | [], None -> assert false
                | (_ :: _ as problems), _ ->
                    ( List.rev_append problems rev_problems,
                      rev_targets,
                      rev_merge_blobs )))
          ([], [], []) entries
      in
      let merge_blobs = List.rev rev_merge_blobs in
      let entry_paths =
        List.fold_left
          (fun set (entry : Change.Net.entry) ->
            Mentat_workspace.Path.Set.add entry.Change.Net.path set)
          Mentat_workspace.Path.Set.empty entries
      in
      let leftover =
        List.map
          (fun path -> Problem.Unmatched_override { path })
          (Mentat_workspace.Path.Set.elements
             (Mentat_workspace.Path.Set.diff override_paths entry_paths))
      in
      let problems = unresolved @ List.rev rev_problems @ leftover in
      match problems with
      | _ :: _ -> Error problems
      | [] -> (
          match List.rev rev_targets with
          | [] -> Error [ Problem.Nothing_to_revert ]
          | targets ->
              (* The frozen consent names exactly the non-contiguous paths
                 that survived into targets: a dropped path is untouched by
                 the plan, so consent for it is never frozen. *)
              let override =
                match override with
                | None -> None
                | Some consent -> (
                    match
                      List.filter
                        (fun path ->
                          List.exists
                            (fun (target : Target.t) ->
                              Mentat_workspace.Path.equal path
                                target.Target.path)
                            targets)
                        (Revert_data.override_paths consent)
                    with
                    | [] -> None
                    | _ :: _ as kept ->
                        Some (Override.accept_unrecorded_loss kept))
              in
              let lower (target : Target.t) =
                let path = target.Target.path in
                let current =
                  match Revert_data.evidence_read evidence path with
                  | Some (Mentat_edit.Observed.Text contents) -> Some contents
                  | Some Mentat_edit.Observed.Missing -> None
                  | Some Mentat_edit.Observed.Other | None -> assert false
                in
                let edit =
                  match (target.Target.restore, current) with
                  | Image.Missing, Some before ->
                      Mentat_edit.delete ~path ~before
                  | Image.Missing, None -> assert false
                  | Image.Text content, current -> (
                      (* The evidence carries every recorded restore blob; a
                         merged restore image the merge branch produced lives in
                         [merge_blobs] instead. *)
                      let contents =
                        match
                          Revert_data.evidence_find_blob evidence content
                        with
                        | Some contents -> contents
                        | None -> (
                            match
                              List.find_opt
                                (fun (reference, _) ->
                                  Mentat_digest.Content_ref.equal reference
                                    content)
                                merge_blobs
                            with
                            | Some (_, contents) -> contents
                            | None -> assert false)
                      in
                      match current with
                      | Some before ->
                          Mentat_edit.rewrite ~path ~before ~after:contents
                      | None -> Mentat_edit.create ~path ~contents)
                in
                match edit with
                | Ok edit -> edit
                | Error error ->
                    invalid "prepare"
                      ("edit lowering failed: "
                      ^ Mentat_edit.Error.message error)
              in
              let edit =
                match Mentat_edit.concat (List.map lower targets) with
                | Ok edit -> edit
                | Error error ->
                    invalid "prepare"
                      ("edit lowering failed: "
                      ^ Mentat_edit.Error.message error)
              in
              let started =
                Revert_data.started ~id ~selection ~targets ~override
              in
              Ok (Revert_data.plan ~started ~edit ~merge_blobs)))

let settle (started : Started.t) outcome =
  let targets = started.Started.targets in
  let revert = started.Started.id in
  let row entry =
    let path = Mentat_edit.Result.Entry.target_path entry in
    let id = Change_id.for_revert ~revert:(Id.to_string revert) path in
    Change.of_entry ~context:"Revert.settle" ~id entry
  in
  (* A confirmed entry must be the frozen transition, positionally: same path,
     before equal to the frozen expected image, after equal to the frozen
     restore image — an outcome from a different apply with coinciding paths
     is a contract breach, never a recorded row with surprising images. *)
  let check_confirmed (target : Target.t) entry confirmed_row =
    if
      not
        (Mentat_workspace.Path.equal target.Target.path
           (Mentat_edit.Result.Entry.target_path entry))
    then
      invalid "settle"
        "apply result entry path does not match its started target";
    if not (Image.equal (Change.before confirmed_row) target.Target.expected)
    then
      invalid "settle"
        "apply result entry does not match the frozen expected image";
    if not (Image.equal (Change.after confirmed_row) target.Target.restore) then
      invalid "settle"
        "apply result entry does not match the frozen restore image"
  in
  match outcome with
  | Ok result ->
      let entries = Mentat_edit.Result.entries result in
      if List.length entries <> List.length targets then
        invalid "settle" "apply result does not cover the started targets";
      let rows = List.map row entries in
      List.iter2
        (fun target (entry, confirmed_row) ->
          check_confirmed target entry confirmed_row)
        targets
        (List.combine entries rows);
      let outcomes =
        List.map2
          (fun (target : Target.t) change ->
            (target.Target.path, Settled.Confirmed (Change.id change)))
          targets rows
      in
      Revert_data.settled ~revert ~outcomes ~changes:rows
        ~disposition:(Settled.Applied { failure = None })
  | Error apply_error -> (
      let error =
        Edit_failure.of_error (Mentat_edit.Apply_error.error apply_error)
      in
      match Mentat_edit.Apply_error.phase apply_error with
      | Mentat_edit.Apply_error.Phase.Preflight ->
          (match Mentat_edit.Apply_error.applied apply_error with
          | [] -> ()
          | _ :: _ ->
              invalid "settle" "preflight failure cannot carry applied entries");
          let outcomes =
            List.map
              (fun (target : Target.t) ->
                (target.Target.path, Settled.Not_attempted))
              targets
          in
          Revert_data.settled ~revert ~outcomes ~changes:[]
            ~disposition:
              (Settled.Applied
                 {
                   failure =
                     Some
                       (Revert_data.stopping_failure
                          ~phase:Settled.Failure.Preflight ~error);
                 })
      | Mentat_edit.Apply_error.Phase.Commit { target = stopping } ->
          let applied = Mentat_edit.Apply_error.applied apply_error in
          let confirmed = List.length applied in
          if confirmed >= List.length targets then
            invalid "settle" "apply error does not match the started targets";
          if
            not
              (Mentat_workspace.Path.equal stopping
                 (List.nth targets confirmed).Target.path)
          then
            invalid "settle"
              "stopping target is not the first unconfirmed started target";
          let rows = Array.of_list (List.map row applied) in
          List.iteri
            (fun i entry -> check_confirmed (List.nth targets i) entry rows.(i))
            applied;
          let outcomes =
            List.mapi
              (fun i (target : Target.t) ->
                let outcome =
                  if i < confirmed then Settled.Confirmed (Change.id rows.(i))
                  else if i = confirmed then Settled.Ambiguous
                  else Settled.Not_attempted
                in
                (target.Target.path, outcome))
              targets
          in
          Revert_data.settled ~revert ~outcomes ~changes:(Array.to_list rows)
            ~disposition:
              (Settled.Applied
                 {
                   failure =
                     Some
                       (Revert_data.stopping_failure
                          ~phase:(Settled.Failure.Commit { target = stopping })
                          ~error);
                 }))

let settle_ambiguous (started : Started.t) =
  let outcomes =
    List.map
      (fun (target : Target.t) -> (target.Target.path, Settled.Ambiguous))
      started.Started.targets
  in
  Revert_data.settled ~revert:started.Started.id ~outcomes ~changes:[]
    ~disposition:Settled.Recovered
