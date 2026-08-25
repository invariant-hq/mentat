(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The lint runner's output, parsed into findings.

    A lint run's combined output carries compiler-shaped diagnostic blocks —
    the format the toolchain shares, parsed here with dune's own parser
    ([ocamlc-loc]) — and possibly noise around them. Everything parsed
    becomes a {!Mentat_ocaml.Finding.Lane.Lint} finding by construction; the
    lane needs no marker and no convention. *)

val findings :
  workspace:Mentat_workspace.t -> string -> Mentat_ocaml.Finding.t list
(** [findings ~workspace output] parses one lint run's combined output:
    every diagnostic block becomes one lint finding — the block's first
    message line as the head, its severity mapped ([Error] to error,
    warnings and alerts to warning), its path resolved workspace-relative
    through [workspace] exactly as stream diagnostics are, an unresolvable
    path keeping the finding and dropping the anchor. A block anchored
    under [_build] is dropped whole: a project lint finding cannot live
    there, and in the dune-exec world the linter's own failed build renders
    its sources' compiler blocks on this very output. Leading text before
    the first block is sliced off; a non-diagnostic line between blocks is
    absorbed into the preceding message's tail, and one past the last block
    ends the parse. A clean run parses to [[]]. *)
