(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The admission gate — is this delivery worth a run?

    A pure predicate over a charter's webhook arm and a decoded
    [pull_request] event. A refusal carries the human-readable reason the
    caller records as the event's skipped disposition; a skip is a quiet
    non-event, never an alert. *)

type verdict =
  | Pass  (** The delivery is worth a run. *)
  | Skip of string  (** Refused, for the carried reason. *)

val evaluate :
  repo:string -> Charter.Trigger.Webhook.t -> Event.Pull_request.t -> verdict
(** [evaluate ~repo webhook event] applies [webhook]'s gate to [event],
    checking in order: the delivery's repository is [repo] — the charter's
    own, so a hook misinstalled on another repository sharing the secret
    is refused here, never at checkout; the delivery's event name
    ([pull_request.<action>]) is among the arm's admitted events; the base
    branch is admitted; the pull request is not an unadmitted draft; the
    author's association is admitted. The first refusal wins and names its
    reason. *)
