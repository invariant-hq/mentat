(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Checkpoint = Mentat_mutation.Checkpoint
module Ports = Mentat_agent.Ports
module Capture = Mentat_store.Capture
module Path = Mentat_workspace.Path
module Rel = Lpath.Rel
module Glob = Mentat_tools.Fs.Glob

(* Observe a revert target through the sealed capability, swallowing the observe
   error to the boundary's default. The swallow is a bin-side caller policy —
   the revert flows treat an unobservable target as {!Mentat_edit.Observed.Other}
   (or absent), never a hard error — so it lives here, not on the capability,
   which reports the fault honestly. *)
let observe capability target =
  match Mentat_workspace_io.Edit.observe capability target with
  | Ok observed -> observed
  | Error _ -> Mentat_edit.Observed.Other

let observe_opt capability target =
  match Mentat_workspace_io.Edit.observe capability target with
  | Ok observed -> Some observed
  | Error _ -> None

(* A generous per-file bound: ordinary source files are covered; a file above it
   is coverage-excluded rather than read into memory. *)
let snapshot_max_bytes = 8 lsl 20

(* The snapshot's own sidecar, when the data home lives inside the workspace, is
   never workspace content a revert should restore; it is pruned beyond the
   ignore rules the walk already honors. *)
let within_self_prefix ~self_prefix path =
  match self_prefix with
  | Some prefix -> Rel.is_within ~root:prefix (Path.rel path)
  | None -> false

(* The covered set is every non-ignored regular file. The walk reuses [Glob]
   over the same sealed capability, so it honors per-directory
   [.gitignore]/[.ignore]/[.rgignore] and prunes version-control metadata:
   build outputs (`_build`), opam switches (`_opam`), vendored trees, and other
   ignored content are never read into a capture. A walk failure surfaces as an
   error message so the boundary degrades honestly rather than capturing a
   silently partial tree; the ignored [self_prefix] is filtered on top. *)
let collect_regular_files capability ~self_prefix =
  let root = Mentat_workspace_io.cwd capability in
  match Mentat_workspace_io.File.lstat capability root with
  | Ok stat when Eio.File.Stat.(stat.kind) = `Directory -> (
      match
        Glob.Enumeration.paths capability
          ~cancelled:(fun () -> false)
          ~root ~pattern:"**"
      with
      | Ok paths ->
          Ok
            (List.filter
               (fun path -> not (within_self_prefix ~self_prefix path))
               paths)
      | Error `Cancelled -> Ok []
      | Error (`Invalid_pattern message) -> Error message
      | Error (`File_error error) ->
          Error (Format.asprintf "%a" Mentat_workspace_io.File_error.pp error))
  | Ok _ | Error _ -> Ok []

let load_regular capability path : Capture.loaded =
  match
    Mentat_workspace_io.File.load capability path ~max_bytes:snapshot_max_bytes
  with
  | Ok bytes -> Capture.Loaded bytes
  | Error
      ( Mentat_workspace_io.File_error.Too_large _
      | Mentat_workspace_io.File_error.Io _ ) ->
      Capture.Excluded
  | Error
      ( Mentat_workspace_io.File_error.Not_found _
      | Mentat_workspace_io.File_error.Escapes_workspace _
      | Mentat_workspace_io.File_error.Unknown_root _ ) ->
      Capture.Skip

let capture_workspace store capability files =
  (* One path per rel: the walk visits each directory once, so the map only
     de-dups defensively. *)
  let table =
    List.fold_left
      (fun table path -> Rel.Map.add (Path.rel path) path table)
      Rel.Map.empty files
  in
  let paths = Rel.Map.fold (fun rel _ acc -> rel :: acc) table [] in
  let load rel =
    match Rel.Map.find_opt rel table with
    | None -> Capture.Skip
    | Some path -> load_regular capability path
  in
  Capture.capture store ~paths ~load

let checkpoint_capture store capability ~self_prefix : Checkpoint.Capture.t =
  let degraded message =
    Checkpoint.Capture.Degraded
      { failure = Checkpoint.Capture.Failure.make ~message }
  in
  match collect_regular_files capability ~self_prefix with
  | Error message -> degraded message
  | Ok files -> (
      match capture_workspace store capability files with
      | Ok { Capture.reference; excluded } ->
          let snapshot =
            Checkpoint.Snapshot.make ~backend:"cas.v1" ~reference
          in
          Checkpoint.Capture.Available { snapshot; excluded }
      | Error error -> degraded (Capture.Error.message error))

let make ~store ?self_prefix ?(notices = fun () -> []) ?watch capability :
    Ports.workspace =
  let checkpoint ~boundary =
    (* The adapter is boundary-agnostic: every boundary captures the workspace
       as it stands now; the boundary is the fact's identity, owned by the
       engine and [mentat.mutation]. *)
    Checkpoint.make ~boundary
      ~capture:(checkpoint_capture store capability ~self_prefix)
  in
  (* The claim id correlates to the tool claim on the adapter side;
     [open_claim_scope] takes none, so it is carried by the caller, not here. *)
  let open_scope (_ : Mentat_session.Tool_claim.Id.t) =
    Option.iter Workspace_watch.claim_opened watch;
    let scope = Mentat_workspace_io.open_claim_scope capability in
    (* The window yields the pure owner type the port crosses on, so the adapter
       adds nothing: the whole [Mentat_edit.Apply_evidence.t] — successes and
       effectful failures alike — passes through. The watch lane's poll
       boundaries bracket the window on the same driver fiber, so its window
       diff lands in the scope before the close that yields the evidence. *)
    fun () ->
      (match watch with
      | None -> ()
      | Some watch ->
          Workspace_watch.claim_window watch
          |> List.iter (fun changed ->
              match Mentat_workspace_io.resolve_path capability changed with
              | Ok path -> Mentat_workspace_io.Claim_scope.observe scope path
              | Error (_ : Mentat_workspace.Resolve_error.t) -> ()));
      Mentat_workspace_io.Claim_scope.close scope
  in
  {
    Ports.identity = Mentat_workspace_io.identity capability;
    checkpoint;
    drain_notices = notices;
    open_scope;
  }
