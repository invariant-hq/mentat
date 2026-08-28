(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The routine pipeline's three GitHub reads, over the first-party client.

    One owner for the read-side conventions every invoker of the fire
    pipeline must agree on: how the open-PR listing's pages flatten into
    typed rows, how a pull request's current head is extracted, and — the
    correctness-bearing one — which posted comments are {e ours}. A caller
    snaps these three onto the pipeline's injected-closure record at its
    call site, so the CLI verb and a resident node can never grow separate
    definitions of any of them.

    All three read with the client's credential; none of them writes.
    Every foreign document is read narrowly — take the members the pipeline
    gates on, ignore the rest — and every error is the client's display-safe
    message. *)

(** One open pull request, as the listing reports it. *)
module Open_pr : sig
  type t = {
    number : int;  (** The pull request number, at least 1. *)
    head_sha : string;  (** The current head commit hash. *)
    base_ref : string;  (** The base branch name. *)
    draft : bool;  (** Whether the pull request is a draft. *)
    author_association : string;
        (** The author's association, GitHub's uppercase token. *)
  }
  (** The type for listed open pull requests — field for field the shape
      the fire pipeline's injected reads carry, so snapping a row onto the
      pipeline's record is a rename, never a judgment. *)
end

val current_head :
  Github_api.t -> repo:string -> number:int -> (string, string) result
(** [current_head api ~repo ~number] is pull request [number]'s current
    head commit hash in [repo] ([owner/name]), or a display-safe failure
    reason — an answer without a [head.sha] member included. *)

val open_prs :
  Github_api.t -> repo:string -> (Open_pr.t list, string) result
(** [open_prs api ~repo] lists [repo]'s open pull requests across
    pagination, in listing order. A listed item missing a needed member is
    passed over, the narrow-read posture every foreign payload gets. *)

val posted :
  Github_api.t -> repo:string -> number:int -> (string, string) result
(** [posted api ~repo ~number] is the JSON array of comments the client's
    credential already posted on pull request [number] — review comments
    and issue comments merged, each an object with [id] and [body]
    members — the renderer's upsert input. A comment is ours iff its
    author is the credential's own login {e and} its body carries a
    publication marker ({!Mentat_connector.Publication.Marker.marks}):
    marker presence alone
    is forgeable, so the author predicate is what makes a comment ours.
    Assumes the read and write credentials share the owner's posting
    identity, which single-owner routines do. *)
