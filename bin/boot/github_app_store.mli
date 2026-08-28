(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The owner-level GitHub App credential home — the on-disk store behind
    [mentatd github setup].

    One App serves every routine, the way one auth store serves every
    session, so the credentials live beside the routines rather than inside
    one: a directory under {!User_dirs.github_app_dir} holding [app.json]
    (the App's identity), [private-key.pem] (the RS256 signing key),
    [webhook-secret] (the App-level HMAC key), [ingress.id] (the minted
    ingress path token), and — written by [mentatd github repoint], absent
    until then — [public-url].

    The custody discipline is {!Routine_store}'s: a group- or
    world-accessible directory or file is refused at load the way sshd
    refuses a loose key, and a half-present home (an [app.json] without its
    key, or the reverse) is refused whole — {!write} is atomic, so a partial
    home indicates tampering or a torn copy, never a normal outcome. Secrets
    are re-read from disk on demand ({!read_key_pem}, {!webhook_secret}):
    the file is the registration, so replacing a file is in force at the
    next event with no reload protocol. The module performs no network
    IO. *)

(** Structured store errors, {!Routine_store.Error}'s shape. *)
module Error : sig
  type t = { operation : string; path : string; reason : string }
  (** [operation] is what failed (load, setup write, secret rotate), [path]
      the file or directory involved, [reason] the rendered cause. *)

  val message : t -> string
  (** [message e] is [e]'s user-facing [<operation>: <path>: <reason>]
      line. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

type t = {
  dir : string;  (** The absolute credential home directory. *)
  app_id : int;  (** The App's numeric id. *)
  slug : string;  (** The App's URL slug — the [<slug>[bot]] identity. *)
  name : string;  (** The App's display name, as GitHub recorded it. *)
  client_id : string;  (** The App's client id — the preferred JWT issuer. *)
  html_url : string;  (** The App's page, [https://github.com/apps/<slug>]. *)
  api_base : string;
      (** The API base the App was created against. A fire or node
          configured with a different base must refuse the App loudly
          rather than send a JWT minted for one host to another. *)
  created_at : string;  (** When setup converted the manifest, RFC 3339. *)
}
(** The type for loaded App identities — [app.json]'s members. Secrets are
    deliberately not carried; {!read_key_pem} and {!webhook_secret} read
    them on demand, so a held identity never holds a stale credential. *)

val load : User_dirs.t -> (t option, Error.t) result
(** [load dirs] reads and validates the credential home: [Ok None] when no
    home exists (App mode is simply not set up), [Ok (Some t)] when it
    loads whole. An [Error] names the first refusal: a group- or
    world-accessible directory or file, an unreadable or strictly-invalid
    [app.json], or a half-present home — any of the four required files
    missing while the directory exists. *)

val posting_login : t -> string
(** [posting_login t] is the login the App's reviews post as —
    [<slug>[bot]] — knowable without any network call, which is what lets
    the App arm of the posted-comments read skip [/user] (an installation
    token cannot call it). *)

val install_url : t -> string
(** [install_url t] is the page where the owner installs the App on
    repositories: [<html_url>/installations/new]. *)

val read_key_pem : t -> (string, Error.t) result
(** [read_key_pem t] is the RS256 private key's PEM bytes, re-read from
    disk — every JWT mint calls it, so replacing the key file is in force
    at the next mint. Refused when the file went missing or loose since
    {!load}. *)

val webhook_secret : t -> (string, Error.t) result
(** [webhook_secret t] is the App-level webhook HMAC key, trimmed,
    re-read from disk per call. *)

val ingress_id : t -> (string, Error.t) result
(** [ingress_id t] is the App's minted ingress path token, trimmed,
    re-read from disk per call — the id [POST /ingress/github/<id>]
    deliveries address. *)

val public_url : t -> (string option, Error.t) result
(** [public_url t] is the public base URL [mentatd github repoint]
    recorded, or [Ok None] while the webhook is unrouted. *)

val fresh_token : unit -> string
(** [fresh_token ()] is a fresh random 128-bit token as 32 lowercase
    hexadecimal characters, from the CSPRNG — the entropy class of a
    routine's ingress id, used for the App's [ingress.id] and for setup's
    one-shot [state]. *)

val fresh_webhook_secret : unit -> string
(** [fresh_webhook_secret ()] is a fresh random 256-bit key as 64
    hexadecimal characters, from the CSPRNG — what [mentatd github
    rotate-secret] writes. *)

val write :
  User_dirs.t ->
  app:t ->
  key_pem:string ->
  webhook_secret:string ->
  ingress_id:string ->
  public_url:string option ->
  (t, Error.t) result
(** [write dirs ~app ~key_pem ~webhook_secret ~ingress_id ~public_url]
    writes the whole credential home atomically: a fresh temporary
    directory beside the final path, every file [0o600] under a [0o700]
    directory, renamed into place — the home exists complete or not at
    all, and re-running setup replaces an existing home whole. [app.dir]
    is ignored; the returned value carries the installed path. *)

val rotate_webhook_secret : t -> (string, Error.t) result
(** [rotate_webhook_secret t] replaces the App's webhook HMAC key with a
    fresh {!fresh_webhook_secret}, written atomically [0o600], and is the
    fresh secret — the caller upserts GitHub's hook config from it. The
    old secret stops verifying the moment the write lands. *)

val write_public_url : t -> string -> (unit, Error.t) result
(** [write_public_url t url] records [url] as the App's public ingress
    base, written atomically [0o600] — [mentatd github repoint]'s local
    half, from which the hook config is derived. *)
