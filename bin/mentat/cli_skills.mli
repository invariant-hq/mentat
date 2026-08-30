(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [skills] diagnostic group: [list] and [show], pure offline views over
    one skill-discovery snapshot (config + trust resolution, no engine). *)

val cmd : int Cmdliner.Cmd.t
