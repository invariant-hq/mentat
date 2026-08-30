(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [commands] diagnostic group: [list] and [show], pure offline views over
    one user-command discovery snapshot (config + trust resolution, no engine).
*)

val cmd : int Cmdliner.Cmd.t
