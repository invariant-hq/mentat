(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Store = Mentat_store
module Ports = Mentat_agent.Ports

let make ~sw ~root ~owner ~now ~merge ~capability ~checkpoint ~new_id :
    (module Ports.STORE) =
  (module struct
    type guard = Store.Run_lock.guard
    type loaded = Store.Session.Document.t

    (* Session-store errors onto the port's arms. A store [Locked] cannot reach
       the engine's fenced path (the engine holds the fence); it is folded into
       [Io] rather than inventing a port arm. *)
    let of_session_error (e : Store.Session.Error.t) : Ports.Store_error.t =
      match e with
      | Store.Session.Error.Not_found _ -> Ports.Store_error.Not_found
      | Store.Session.Error.Already_exists _ | Store.Session.Error.Conflict _ ->
          Ports.Store_error.Conflict
      | Store.Session.Error.Locked _ | Store.Session.Error.Corrupt _
      | Store.Session.Error.Io _ ->
          Ports.Store_error.Io (Store.Session.Error.diagnostic e)

    let of_mutation_error ~session (e : Store.Mutation.Error.t) :
        Ports.Store_error.t =
      match e with
      | Store.Mutation.Error.Io _ ->
          Ports.Store_error.Io (Store.Mutation.Error.diagnostic ~session e)
      | Store.Mutation.Error.Document (Store.Session.Error.Io _) ->
          Ports.Store_error.Io (Store.Mutation.Error.diagnostic ~session e)
      | Store.Mutation.Error.Document (Store.Session.Error.Conflict _) ->
          Ports.Store_error.Conflict
      | Store.Mutation.Error.Invalid_line _
      | Store.Mutation.Error.Invalid_history _
      | Store.Mutation.Error.Correlation _ | Store.Mutation.Error.Document _
      | Store.Mutation.Error.Blob_mismatch _
      | Store.Mutation.Error.Missing_blob _
      | Store.Mutation.Error.Non_regular_file _ ->
          Ports.Store_error.Corrupt (Store.Mutation.Error.diagnostic ~session e)

    (* The wire outcome the online port carries: [Session_meta.revert] keeps the
       refusal structured, so the online cone projects it to the port's
       string-valued [Refused] here — the offline twin instead reads the
       structured problems for its consent surface. *)
    let outcome_of_store :
        Store.Mutation.revert_outcome -> Mentat_mutation.Revert.Outcome.t =
      function
      | Store.Mutation.Nothing_to_revert ->
          Mentat_mutation.Revert.Outcome.Nothing_to_revert
      | Store.Mutation.Refused problems ->
          Mentat_mutation.Revert.Outcome.Refused
            (List.map Mentat_mutation.Revert.Problem.message problems)
      | Store.Mutation.Applied settled ->
          Mentat_mutation.Revert.Outcome.Applied settled

    let session_of = Store.Session.Document.session

    let try_acquire id =
      match Store.Run_lock.try_acquire ~sw root ~session:id ~owner with
      | Ok guard -> `Acquired guard
      | Error (`Held holder) ->
          `Held
            (Option.map
               (fun o -> Format.asprintf "%a" Store.Run_lock.Owner.pp o)
               holder)
      | Error (`Io io) -> `Io (Mentat_diagnostic.of_text (Store.Io.message io))

    let release = Store.Run_lock.release

    let create session =
      Result.map_error of_session_error (Store.Session.create root session)

    let fork ~from ~events session =
      Result.map_error of_session_error (Store.fork root ~from ~events session)

    let load guard =
      let id = Store.Run_lock.session guard in
      Result.map_error of_session_error (Store.Session.load root id)

    let view id = Result.map_error of_session_error (Store.Session.load root id)

    let commit guard loaded events =
      let base = Store.Session.Document.session loaded in
      match Mentat_session.append_all events base with
      | Error e -> Error (Ports.Store_error.Rejected e)
      | Ok appended ->
          let stamped = Mentat_session.touch (now ()) appended in
          Result.map_error of_session_error
            (Store.Session.commit root ~fence:guard loaded stamped)

    let commit_metadata guard loaded session =
      let stamped = Mentat_session.touch (now ()) session in
      Result.map_error of_session_error
        (Store.Session.commit root ~fence:guard loaded stamped)

    let append_edit guard loaded ~entries event =
      let session = Store.Run_lock.session guard in
      Result.map_error
        (of_mutation_error ~session)
        (Store.Mutation.append_edit root ~fence:guard ~document:loaded ~entries
           event)

    let append_mutation guard loaded events =
      let session = Store.Run_lock.session guard in
      Result.map_error
        (of_mutation_error ~session)
        (Store.Mutation.append root ~fence:guard ~document:loaded events)

    let mutation_events loaded =
      let id = Store.Session.Document.id loaded in
      match Store.Mutation.read root loaded with
      | Error e -> Error (of_mutation_error ~session:id e)
      | Ok state -> Ok (Mentat_mutation.State.events state)

    let blob id ref =
      Result.map_error
        (of_mutation_error ~session:id)
        (Store.Mutation.blob root ~session:id ref)

    (* The attachment namespace is fence-free like the capture store: an attach
       happens before the run fence exists ([-i]) or with no active turn (TUI).
       Integrity failures map to [Corrupt], IO to [Io], mirroring [blob]. *)
    let of_attachment_error ~session (e : Store.Attachment.Error.t) :
        Ports.Store_error.t =
      match e with
      | Store.Attachment.Error.Io _ ->
          Ports.Store_error.Io (Store.Attachment.Error.diagnostic ~session e)
      | Store.Attachment.Error.Blob_mismatch _
      | Store.Attachment.Error.Non_regular_file _ ->
          Ports.Store_error.Corrupt
            (Store.Attachment.Error.diagnostic ~session e)

    let put_attachment id bytes =
      Result.map_error
        (of_attachment_error ~session:id)
        (Store.Attachment.put root ~session:id bytes)

    let attachment id ref =
      Result.map_error
        (of_attachment_error ~session:id)
        (Store.Attachment.get root ~session:id ref)

    (* The online revert cone: resolve the scope and run the fenced lifecycle
       through the shared assembly, closing over this adapter's workspace-write
       capability (observe/apply), boundary checkpoint, and revert-id minter. The
       offline twin composes the same {!Session_meta.revert} under its own
       acquire. *)
    let revert guard loaded ~scope =
      let session = Store.Run_lock.session guard in
      let observe = Workspace_adapter.observe capability in
      Result.map_error
        (of_mutation_error ~session)
        (Result.map outcome_of_store
           (Session_meta.revert_scope ~merge ~override:None ~store:root
              ~fence:guard ~document:loaded ~scope ~observe ~checkpoint
              ~apply:(Mentat_workspace_io.Edit.apply capability)
              ~new_id))

    (* The undo cone's file half: a multi-turn or multi-change [Selection] the
       online [revert] scope cannot express, run through the same fenced
       lifecycle assembly. The undo flow drives it for the boundary revert and
       the widen/narrow un-revert. *)
    let revert_selection guard loaded ~selection =
      let session = Store.Run_lock.session guard in
      let observe = Workspace_adapter.observe capability in
      Result.map_error
        (of_mutation_error ~session)
        (Result.map outcome_of_store
           (Session_meta.revert ~merge ~override:None ~store:root ~fence:guard
              ~document:loaded ~selection:(Some selection) ~observe ~checkpoint
              ~apply:(Mentat_workspace_io.Edit.apply capability)
              ~new_id))

    (* The undo commit's truncate: drop the crossed turns from both durable
       halves under one document lock, ledger-first. The caller supplies the
       surviving-prefix [session] document and the [keep] predicate; the ledger
       prefix is derived here from the current validated history. Returns the new
       document and the post-truncate mutation anchor the driver adopts. *)
    let truncate guard loaded ~keep session =
      let id = Store.Run_lock.session guard in
      match Store.Mutation.read root loaded with
      | Error e -> Error (of_mutation_error ~session:id e)
      | Ok mstate ->
          let ledger = Mentat_mutation.State.prefix_for_turns mstate ~keep in
          Result.map_error of_session_error
            (Store.truncate root ~fence:guard ~document:loaded ~ledger session)

    (* The online export cone: buffer the whole fenced bundle into one value —
       the frontend owns where the bytes land, and the engine size-guards it
       before it crosses the wire. *)
    let export guard =
      let session = Store.Run_lock.session guard in
      let buf = Buffer.create 4096 in
      match
        Store.Export.write ~root ~fence:guard ~write:(Buffer.add_string buf)
      with
      | Ok () -> Ok (Buffer.contents buf)
      | Error (`Session e) -> Error (of_session_error e)
      | Error (`Mutation e) -> Error (of_mutation_error ~session e)
  end)
