(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Terminal output primitives shared by every command.

    stdout carries results and content (tables, JSON, headless final text);
    stderr carries posture, hints, warnings, and errors. Both channels flush on
    every write so interleaving with a child process's output is deterministic.
    JSON is one enveloping discipline (schema_version + type) so scripts read a
    uniform shape.

    Output discipline: the executable emits no escape sequences of its own and
    disables all third-party styling at process start ({!init}, {!help_ppf},
    {!err_ppf}); model-originated text on the human path is sanitized
    unconditionally ({!model_text}); every JSON output — success and error — is
    one envelope ({!Json.envelope}, {!json_error}). *)

val init : unit -> unit
(** [init ()] disables third-party ANSI styling at process start: the Jsont
    decode-error styler (whose SGR codes otherwise leak into config
    diagnostics). Called once by {!Main} before [Cmd.eval']. Idempotent.
    cmdliner styling is stripped separately through {!help_ppf}/{!err_ppf},
    which this cmdliner version requires because it exposes no runtime styler
    toggle. *)

val stdout_printf : ('a, out_channel, unit) format -> 'a
(** [stdout_printf fmt …] prints to stdout and flushes. Executable-authored text
    only — never model-originated (use {!model_text} for that). *)

val stderr_printf : ('a, out_channel, unit) format -> 'a
(** [stderr_printf fmt …] prints to stderr and flushes. *)

val model_text : string -> unit
(** [model_text text] prints [text] followed by a newline to stdout with every
    C0 control byte except [\n] and [\t] — and DEL — stripped. The one sink for
    assistant/model prose on the human path: an OSC title-set or CSI sequence in
    untrusted model output is a terminal-injection attack on a TTY and noise in
    a file, so it is removed unconditionally, not TTY-gated. The [--json] path
    escapes model text through the codec and does not use this. *)

val model_delta : string -> unit
(** [model_delta text] streams [text] to stdout through the same C0/DEL
    sanitizer as {!model_text} but with {b no} trailing newline, force-flushed
    like every stdout write. The streaming counterpart of {!model_text}: the
    headless run path prints assistant prose delta by delta as it arrives and
    closes the line itself at the step boundary. The sanitizer is byte-local, so
    it distributes over concatenation and cannot corrupt a UTF-8 character split
    across two deltas. *)

val sanitize_c0 : string -> string
(** [sanitize_c0 text] is [text] with every C0 control byte except [\n] and [\t]
    — and DEL — removed. Exposed so the run path can reconcile the bytes it
    streamed through {!model_delta} against the authoritative assistant text:
    both sides sanitize, so a per-chunk stream and a whole-text reconcile agree
    byte for byte. Byte-local and idempotent. *)

val print_table : header:string list -> string list list -> unit
(** [print_table ~header rows] renders one aligned table to stdout: column
    widths measured in codepoints, two-space separators, the last column
    unpadded, trailing spaces trimmed. *)

val help_ppf : Format.formatter
(** A formatter for cmdliner's help output that strips ANSI escapes before
    writing to stdout. Passed as [Cmd.eval' ~help]. *)

val err_ppf : Format.formatter
(** A formatter for cmdliner's usage/error output that strips ANSI escapes
    before writing to stderr. Passed as [Cmd.eval' ~err]. *)

val flush_cmdliner : unit -> unit
(** [flush_cmdliner ()] flushes {!help_ppf} and {!err_ppf}, emitting any pending
    (stripped) cmdliner output. Called by {!Main} after [Cmd.eval'] in case
    cmdliner left content unflushed. *)

val json_error : type_:string -> string -> unit
(** [json_error ~type_ message] prints one error envelope
    [{schema_version:1, type, error}] to stdout — the single machine-readable
    error sink so [--json] error paths are enveloped, never a bare [mentat:]
    line with no JSON. *)

(** {1:json JSON} *)

module Json : sig
  (** Envelope-first JSON construction over {!Jsont.Json}. *)

  val to_string : Jsont.json -> string
  (** [to_string json] is [json] pretty-printed. Raises [Failure] if the value
      cannot encode (an executable bug, never untrusted input). *)

  val obj : (string * Jsont.json) list -> Jsont.json
  (** [obj fields] is a JSON object with [fields] in order. *)

  val envelope : type_:string -> (string * Jsont.json) list -> Jsont.json
  (** [envelope ~type_ fields] prepends [schema_version] (always [1]) and [type]
      to [fields] — the one enveloping discipline every enveloped payload uses.
  *)

  val string : string -> Jsont.json
  val int : int -> Jsont.json
  val bool : bool -> Jsont.json
  val null : Jsont.json
  val list : Jsont.json list -> Jsont.json
  val string_or_null : string option -> Jsont.json
  val int_or_null : int option -> Jsont.json
end
