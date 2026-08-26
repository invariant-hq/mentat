(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The on-disk charter estate — the executable-side half over the pure
    [mentat_charter] library.

    A charter lives as one directory under {!User_dirs.charters_dir}:
    [charter.json], the prompt and output-schema files it names, and — for a
    webhook charter — [ingress.id] and [secrets/]. Its durable record lives
    apart, under {!User_dirs.charter_state_dir}: the append-only receipt log
    and the per-event-identity claim markers, which removing the
    configuration deliberately leaves in place. This module owns reading,
    installing, and recording; deciding — gates, fences, spawning — is its
    callers' business, composed over the values it returns. It performs no
    network IO, opens no store, and drives no engine.

    Every load re-reads and re-validates the files — the file is the
    registration, so there is no cache to invalidate and an owner's edit is
    in force at the next event. A group- or world-accessible charter
    directory or secret file is refused the way sshd refuses a loose key. *)

(** Structured store errors. Callers recover identically, but the message
    retains the operation and path — not flattened to an unstructured
    string. *)
module Error : sig
  type t = { operation : string; path : string; reason : string }
  (** [operation] is what failed (load, install, receipt append), [path] the
      file or directory involved, [reason] the rendered cause. *)

  val message : t -> string
  (** [message e] is [e]'s user-facing [<operation>: <path>: <reason>]
      line. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

(** A charter as loaded from its directory. *)
module Loaded : sig
  type t = {
    name : string;  (** The charter's name — also its directory's basename. *)
    dir : string;  (** The absolute charter directory. *)
    charter : Mentat_charter.Charter.t;  (** The decoded document. *)
    digest : string;
        (** The policy digest over [charter.json], the prompt file, and the
            output-schema file — 16 lowercase hexadecimal characters. *)
    prompt : string;  (** The prompt file's bytes. *)
    output_schema : string;  (** The output-schema file's bytes. *)
    ingress_id : string option;
        (** The minted ingress path token, when [ingress.id] exists. *)
  }
  (** The type for loaded charters: the full policy closure, so a consumer
      spawning a run or computing the digest needs no second read. Secrets
      are deliberately not carried — {!read_secret} and {!Binding.t} are
      the two surfaces that read one, both on demand, so a held closure
      never holds a stale credential. *)
end

val read_secret : Loaded.t -> file:string -> (string option, Error.t) result
(** [read_secret loaded ~file] is the trimmed content of [file] under the
    charter's [secrets/] directory — [read-token], [write-token], or
    [secrets/webhook]'s [webhook] — or [Ok None] when the file does not
    exist. One policy for every credential read: surrounding whitespace is
    trimmed (an editor's trailing newline is not part of a secret), and a
    present-but-blank file is an [Error], never an empty token. *)

val load : User_dirs.t -> name:string -> (Loaded.t, Error.t) result
(** [load dirs ~name] reads and validates the installed charter [name]. An
    [Error] names the first refusal: a missing directory, a directory or
    [secrets/] entry that is group- or world-accessible, an unreadable or
    strictly-invalid [charter.json], a document whose [name] member differs
    from the directory's basename, an unreadable prompt or schema file, or —
    for a charter with a webhook arm — a missing [ingress.id] or
    [secrets/webhook] (with the hint to run [charter add], which mints
    them). *)

val roster :
  User_dirs.t -> ((string * (Loaded.t, Error.t) result) list, Error.t) result
(** [roster dirs] is every installed charter by name, sorted, each carrying
    its {!load} result — a broken charter is a named error in the roster,
    never an omission. A missing charters directory is an empty roster.
    Entries opening with a dot are ignored (the platform's own droppings,
    never a charter — {!install} refuses a dot-leading name). The outer
    [Error] is an unreadable charters directory. *)

(** One webhook charter's ingress binding. *)
module Binding : sig
  type t = {
    name : string;  (** The charter's name. *)
    id : string;  (** The [ingress.id] path token deliveries address. *)
    secret : string;
        (** The HMAC key from [secrets/webhook], surrounding whitespace
            trimmed — an editor's trailing newline is not part of the
            secret. *)
    enabled : bool;  (** The charter's [enabled] member. *)
  }
  (** The type for ingress bindings — the resolver's answer shape: a
      disabled charter still binds, so its deliveries verify against the
      retained secret rather than leaking their refusal to the sender. *)
end

val ingress_index :
  User_dirs.t ->
  (Binding.t list * (string * Error.t) list, Error.t) result
(** [ingress_index dirs] folds the installed charters into the bindings a
    webhook listener resolves ingress ids against: one {!Binding.t} per
    loadable charter with a webhook arm, plus the charters that failed to
    load, by name — a broken charter answers to no id, and the caller
    decides how loudly to say so. The outer [Error] is an unreadable
    charters directory. *)

(** {1:record The durable record}

    The per-event-identity run-claim marker and the receipt log split one
    job. The marker — created [O_CREAT|O_EXCL] at the moment a pass commits
    to spawning a run, after every gate and fence has admitted the event —
    is the {e serialization} point: it collapses concurrent committers of
    one event across processes to a single winner, and its presence means
    this identity committed a run, so every later delivery and every sweep
    pass reads it as a duplicate. A refusal that is not a commitment — a
    gate skip, a fence — never claims, so the event re-enters when its
    circumstances change. The fsynced JSONL append is the {e durability}
    point, the authoritative record folds read. A pass that finds the
    marker held consults the log's spawned line
    ({!Mentat_charter.Receipt.spawn_recorded}) to tell a completed
    commitment from one abandoned between claim and spawn. *)

val claim_identity :
  User_dirs.t ->
  name:string ->
  digest:string ->
  Mentat_charter.Event.Identity.t ->
  ([ `Claimed | `Dup ], Error.t) result
(** [claim_identity dirs ~name ~digest identity] commits [identity] to one
    run under the policy [digest]: [`Claimed] created the marker, [`Dup]
    found it already held. The marker is keyed on [(digest, identity)] — a
    policy edit re-admits every event, exactly as the run-id mint re-runs
    it. The marker file carries [identity]'s string form for a human
    reader; nothing parses it. *)

val claim_held :
  User_dirs.t ->
  name:string ->
  digest:string ->
  Mentat_charter.Event.Identity.t ->
  bool
(** [claim_held dirs ~name ~digest identity] is [true] iff the run-claim
    marker for [identity] under [digest] exists — the read-only probe. A
    [false] answer is advisory (another pass may commit in the next
    instant); only {!claim_identity}'s exclusive create decides. *)

val append_receipt :
  User_dirs.t ->
  name:string ->
  Mentat_charter.Receipt.t ->
  (unit, Error.t) result
(** [append_receipt dirs ~name receipt] appends [receipt] as one line of the
    charter's [receipts.jsonl], durably ({!Fs.append}'s ledger
    discipline). *)

val read_receipts :
  User_dirs.t -> name:string -> (Mentat_charter.Receipt.t list, Error.t) result
(** [read_receipts dirs ~name] is the charter's receipts in log order; a
    missing log is the empty list. Each newline-terminated line is decoded
    strictly — a line this build cannot read is an [Error] naming its
    number, never a silent skip. An unterminated final fragment is not a
    record: it is the crash artifact the appender's boundary repair
    truncates, so the read ignores it — the same absence the repair
    produces. *)

(** {1:install Installing} *)

(** What {!install} did. *)
module Installed : sig
  type webhook = {
    id : string;  (** The ingress path token in force after the install. *)
    id_minted : bool;
        (** [true] when [ingress.id] was minted by this install — the
            webhook URL is fresh and GitHub settings must follow. *)
    secret_minted : bool;
        (** [true] when [secrets/webhook] was minted by this install. *)
  }
  (** The webhook identity outcome, for charters with a webhook arm. *)

  type t = {
    loaded : Loaded.t;  (** The installed charter, re-loaded and valid. *)
    webhook : webhook option;
        (** [None] for a charter with no webhook arm. *)
  }
  (** The type for install outcomes. *)
end

val install : User_dirs.t -> src:string -> (Installed.t, Error.t) result
(** [install dirs ~src] validates the charter at [src] — a charter directory,
    or a path to its [charter.json] — and installs it under its own name:
    the three policy files ([charter.json], prompt, schema) are copied into
    {!User_dirs.charter_dir}, each written [0o600] with the directory chain
    [0o700]; for a webhook charter, [ingress.id] (a random 128-bit token,
    32 lowercase hexadecimal characters) and [secrets/webhook] (a random
    256-bit key, 64 hexadecimal characters) are minted where absent and kept
    where present — minting is once, so an owner's edits never move the
    webhook URL. Re-installing over an existing charter replaces the policy
    files (the digest moves, resetting fence windows) and keeps identity and
    secrets. When [src] is the installed directory itself, nothing is
    copied — the call validates in place and mints what is missing.

    Refused with a named [Error]: an invalid or unreadable source (the
    library's strict decode error, verbatim), a name opening with a dot, and
    a {e proposal} — a source other than the installed directory — carrying
    [secrets/] or [ingress.id], since secrets never ride a proposal and a
    webhook identity is minted here, never imported. *)
