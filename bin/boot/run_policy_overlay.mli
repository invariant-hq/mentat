(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The one lowering home for a recorded run policy's configuration half.

    A trigger-born session's document records the run contract its creator
    granted. Two consumers share this lowering: the serving boot lowers the
    members onto its configuration overlay before the engine is built, and
    the charter fire runs the same lowering against an empty configuration
    as a pre-flight, so a contract no activation could serve refuses before
    the identity is claimed or anything is spent. One home, because a
    fire-side copy would drift from the boot it predicts. *)

val of_policy :
  Mentat_session.Metadata.Run_policy.t ->
  (Mentat_config.t option, string) result
(** [of_policy policy] lowers [policy]'s configuration members — the sandbox
    mode, the sandbox requirement, the step cap, the model and reasoning
    selectors, the unattended permission policy, and the
    project-instructions toggle — onto one overlay, validated by the
    configuration layer that will apply them. [Ok None] when the policy
    names no configuration member. The mode and the output schema are not
    lowered: queue admission reads them from the document at each admitted
    turn. An [Error] names the refusing member and the configuration
    layer's reason, e.g. ["sandbox: unknown mode ..."]. *)
