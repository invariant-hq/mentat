(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  instance : Mentat_ocaml_dune_rpc.Instance.t;
  mutable stated : Mentat_workspace.Build_change.State.t;
}

let make ~instance () =
  { instance; stated = Mentat_workspace.Build_change.State.initial }

let drain t =
  let snapshot = Mentat_ocaml_dune_rpc.Instance.snapshot t.instance in
  let changes, stated =
    Mentat_workspace.Build_change.step t.stated
      snapshot.Mentat_ocaml_dune_rpc.Instance.Snapshot.reading
  in
  t.stated <- stated;
  List.map Mentat_workspace.Build_change.notice changes

let health_of instance =
  let snapshot = Mentat_ocaml_dune_rpc.Instance.snapshot instance in
  match snapshot.Mentat_ocaml_dune_rpc.Instance.Snapshot.status with
  | Mentat_ocaml_dune_rpc.Instance.Watch.Absent ->
      Mentat_workspace.Health.Off Mentat_workspace.Health.Off.No_server
  | Mentat_ocaml_dune_rpc.Instance.Watch.Connecting _ ->
      Mentat_workspace.Health.Probing
  | Mentat_ocaml_dune_rpc.Instance.Watch.Attached { pid } ->
      let phase =
        match snapshot.Mentat_ocaml_dune_rpc.Instance.Snapshot.reading with
        | Some reading
          when not snapshot.Mentat_ocaml_dune_rpc.Instance.Snapshot.building ->
            Mentat_workspace.Health.Phase.Settled
              {
                build = Mentat_workspace.Build_change.Reading.verdict reading;
                lint = Mentat_workspace.Build_change.Reading.lint reading;
              }
        | Some _ | None -> Mentat_workspace.Health.Phase.Building
      in
      Mentat_workspace.Health.Live
        { owner = Mentat_workspace.Health.Owner.Theirs pid; phase }

let health t = health_of t.instance
