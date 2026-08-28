(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let policy_digest_hex s =
  String.length s = 16
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       s

let mint ~policy_digest identity =
  if not (policy_digest_hex policy_digest) then
    invalid_arg "Run_id.mint: policy_digest must be 16 lowercase hex characters";
  "c-"
  ^ Mentat_digest.key ~length:16 ~domain:"mentat.routine.run.v1"
      [ policy_digest; Event.Identity.to_string identity ]
