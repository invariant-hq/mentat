(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type verdict = Pass | Skip of string

let evaluate ~repo (webhook : Charter.Trigger.Webhook.t)
    (event : Event.Pull_request.t) =
  let { Charter.Trigger.Webhook.events; gate } = webhook in
  let { Charter.Gate.base; drafts; associations } = gate in
  let {
    Event.Pull_request.action;
    base_ref;
    draft;
    author_association;
    number = _;
    head_sha = _;
    repo = event_repo;
  } =
    event
  in
  let event_name = "pull_request." ^ action in
  if not (String.equal event_repo repo) then
    Skip
      (Printf.sprintf "repository %S is not the charter's %S" event_repo repo)
  else if not (List.mem event_name events) then
    Skip (Printf.sprintf "event %S is not in the charter's events" event_name)
  else
    match base with
    | Some branches when not (List.mem base_ref branches) ->
        Skip (Printf.sprintf "base branch %S is not admitted" base_ref)
    | Some _ | None -> (
        if draft && not drafts then Skip "draft pull requests are not admitted"
        else
          match associations with
          | Some admitted when not (List.mem author_association admitted) ->
              Skip
                (Printf.sprintf "author association %s is not admitted"
                   author_association)
          | Some _ | None -> Pass)
