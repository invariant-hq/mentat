(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The mode-resolved per-fire repository connection — one builder shared by
    the CLI fire and the resident node, so the two invokers can never grow
    separate answers to which credential a routine fires with.

    The mode is {!Routine_store.auth_mode}'s: PAT files win, else the
    owner-level App, else a refusal naming both exits. The PAT arm is the
    existing journey byte for byte — the read token client, [/user] for the
    posting identity, [secrets/write-token] at publish time. The App arm
    mints per fire and holds nothing: a fresh JWT over the re-read key, the
    installation resolved for the watched repository, a read-scoped
    installation token for the client, the git fetch, and the API reads;
    the posting identity is the stored [<slug>[bot]] with no network call;
    and the write closure re-mints a write-scoped token at publish time.
    Tokens live only in the returned closures' memory — nothing here or in
    any caller may retain a connection across fires. *)

val repo :
  dirs:User_dirs.t ->
  net:_ Eio.Net.t ->
  base_url:string option ->
  git_url:string ->
  Routine_store.Loaded.t ->
  (Routine_fire.Repo.t, string) result
(** [repo ~dirs ~net ~base_url ~git_url loaded] is the per-fire connection
    for [loaded], mode-resolved and built fresh — credentials re-read or
    re-minted per call, so a rotated token or a replaced key is in force at
    the next event. [base_url] overrides the GitHub API base
    ([https://api.github.com] otherwise); in App mode a base that differs
    from the one the App was created against is refused loudly rather than
    sending a JWT minted for one host to another. [Error message] is
    display-safe and never carries a credential: a missing PAT read token,
    a credential home that does not load, an uninstalled App (the install
    page named), a refused mint, or — neither mode configured — the
    refusal naming both exits. *)
