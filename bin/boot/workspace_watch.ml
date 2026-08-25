(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Glob = Mentat_tools.Fs.Glob
module Notice = Mentat_workspace.Notice
module Rel = Lpath.Rel

let source = "fswatch"

(* Queued external events are bounded; the notice body previews a fixed head
   and the count stays honest through [total]. *)
let max_pending = 1024
let max_preview = 20

type state = Watching of Fswatch.t | Degraded of Fswatch.Error.t option
(* [Some] until the failure has been drained as a warning notice. *)

type t = {
  root : string;
  mutable state : state;
  mutable pending_rev : Fswatch.Event.t list;
  mutable total : int;
}

(* Ignoring a directory component excludes its whole subtree, exactly like the
   capture walk's pruning: watching version control metadata, build and switch
   artifacts, or mentat's own data would attribute machinery churn to the
   workspace. *)
let component_ignored component =
  List.exists (String.equal component) Mentat_workspace.observation_prune_names

(* The workspace's own ignore files name the trees that are not workspace
   content — reference checkouts, eval outputs, vendored code — which the fixed
   component set cannot anticipate; one unpruned gitignored tree can exhaust
   the scanner's entry budget and degrade the watcher. The rules go through
   the same parser as the capture walk's, read once at watcher start; only the
   root's ignore files are consulted, so a nested ignore file refines captures
   but not this watcher. An unreadable or oversized ignore file contributes no
   rules. *)
let root_ignore_rules root =
  List.fold_left
    (fun rules name ->
      match
        Fs.read_capped ~max_bytes:Fs.default_max_bytes
          (Filename.concat root name)
      with
      | Ok (Some contents) ->
          Glob.Ignore.join rules (Glob.Ignore.parse contents)
      | Ok None | Error _ -> rules)
    Glob.Ignore.empty
    [ ".gitignore"; ".ignore"; ".rgignore" ]

let default_ignore ~ignore_prefix ~rules path =
  (* The watcher speaks its own root-relative [Fswatch.Path.t]; convert once to
     the workspace path vocabulary the ignore policy is written against. The
     watcher only yields well-formed renderings, so [of_string_exn] cannot
     raise. *)
  let path = Rel.of_string_exn (Fswatch.Path.to_string path) in
  (match ignore_prefix with
    | Some prefix -> Rel.is_within ~root:prefix path
    | None -> false)
  || (match Rel.to_string path with
    | "." -> false
    | text -> String.split_on_char '/' text |> List.exists component_ignored)
  || Glob.Ignore.prunes rules path

let start ~sw ~clock ?ignore_prefix ~root () =
  let root = Lpath.Abs.to_string root in
  let rules = root_ignore_rules root in
  let state =
    match
      Fswatch.make ~sw ~clock ~backend:`Polling
        ~ignore:(default_ignore ~ignore_prefix ~rules)
        ~root ()
    with
    | Ok watcher -> Watching watcher
    | Error error -> Degraded (Some error)
  in
  { root; state; pending_rev = []; total = 0 }

let advance t =
  match t.state with
  | Degraded _ -> []
  | Watching watcher -> (
      match Fswatch.poll watcher with
      | Ok events -> events
      | Error error ->
          Fswatch.close watcher;
          t.state <- Degraded (Some error);
          [])

let queue_external t events =
  List.iter
    (fun event ->
      t.total <- t.total + 1;
      if List.length t.pending_rev < max_pending then
        t.pending_rev <- event :: t.pending_rev)
    events

let claim_opened t = queue_external t (advance t)

let claim_window t =
  advance t
  |> List.filter_map (fun { Fswatch.Event.path; kind = _ } ->
      if Fswatch.Path.is_root path then None
      else Some (Filename.concat t.root (Fswatch.Path.to_string path)))

let kind_text = function
  | Fswatch.Event.Created -> "created"
  | Fswatch.Event.Deleted -> "deleted"
  | Fswatch.Event.Changed -> "changed"

let event_line event =
  "- "
  ^ kind_text event.Fswatch.Event.kind
  ^ " "
  ^ Fswatch.Path.to_string event.Fswatch.Event.path

let change_notice t events =
  let shown =
    List.filteri (fun index _ -> index < max_preview) events
    |> List.map event_line
  in
  let count = t.total in
  (* The count leads the title so the live footer glances as a headline; the
     body carries the file list the durable transcript entry renders in full. *)
  let title =
    Printf.sprintf "%d workspace file change%s since the last scan" count
      (if count = 1 then "" else "s")
  in
  let more =
    if count > List.length shown then
      [ Printf.sprintf "- ... and %d more" (count - List.length shown) ]
    else []
  in
  let body = String.concat "\n" (shown @ more) in
  Notice.make ~source ~severity:Notice.Severity.Info ~title ~body
    ~key:("fswatch\000" ^ t.root) ()

let failure_notice t error =
  Notice.make ~source ~severity:Notice.Severity.Warning
    ~title:"Filesystem watcher error"
    ~body:(Fswatch.Error.message error)
    ~key:("fswatch-error\000" ^ t.root)
    ()

let drain t =
  queue_external t (advance t);
  let events = List.rev t.pending_rev in
  let changes =
    match events with [] -> [] | _ :: _ -> [ change_notice t events ]
  in
  t.pending_rev <- [];
  t.total <- 0;
  let failure =
    match t.state with
    | Degraded (Some error) ->
        t.state <- Degraded None;
        [ failure_notice t error ]
    | Degraded None | Watching _ -> []
  in
  changes @ failure
