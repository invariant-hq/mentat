(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pull-request reads over the {!Api} client.

    Four read-only queries a pull-request automation gates on: how the
    open-PR listing's pages flatten into typed rows, how a pull request's
    current head is extracted, whose credential is doing the reading, and —
    the correctness-bearing one — which posted comments are the caller's
    own.

    All four read with the client's credential; none of them writes. Every
    foreign document is read narrowly — take the members the caller gates
    on, ignore the rest — and every error is the client's display-safe
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
  (** The type for listed open pull requests. *)
end

val current_head :
  Api.t -> repo:string -> number:int -> (string, string) result
(** [current_head api ~repo ~number] is pull request [number]'s current
    head commit hash in [repo] ([owner/name]), or a display-safe failure
    reason — an answer without a [head.sha] member included. *)

val open_prs : Api.t -> repo:string -> (Open_pr.t list, string) result
(** [open_prs api ~repo] lists [repo]'s open pull requests across
    pagination, in listing order. A listed item missing a needed member is
    passed over, the narrow-read posture every foreign payload gets. *)

val viewer_login : Api.t -> (string, string) result
(** [viewer_login api] is the login of the credential's own account, from
    [GET /user] — a personal access token's posting identity. An
    installation token cannot call [/user] (403 by design); a GitHub App's
    posting identity is its [<slug>[bot]] login, knowable without any
    network call, so App callers never call this. *)

val posted :
  Api.t ->
  login:string ->
  marked:(string -> bool) ->
  repo:string ->
  number:int ->
  (string, string) result
(** [posted api ~login ~marked ~repo ~number] is the JSON array of comments
    the posting identity [login] already posted on pull request [number] —
    review comments and issue comments merged, each an object with [id]
    and [body] members, encoded as one JSON document. A comment counts iff
    its author is [login] {e and} [marked] holds of its body — the
    caller's own way of recognizing the comments it writes, a marker line
    say. A recognizable body alone is forgeable by any commenter, so the
    author predicate is what makes a comment the caller's. Assumes the
    read and write credentials share the posting identity. *)
