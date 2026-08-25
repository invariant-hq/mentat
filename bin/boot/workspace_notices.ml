(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  instance : Mentat_ocaml_dune_rpc.Instance.t;
  mutable stated : Mentat_ocaml.Build_change.State.t;
}

let make ~instance () =
  { instance; stated = Mentat_ocaml.Build_change.State.initial }

let drain t =
  let snapshot = Mentat_ocaml_dune_rpc.Instance.snapshot t.instance in
  let changes, stated =
    Mentat_ocaml.Build_change.step t.stated
      snapshot.Mentat_ocaml_dune_rpc.Instance.Snapshot.reading
  in
  t.stated <- stated;
  List.map Mentat_ocaml.Build_change.notice changes
