(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** One-row display arguments for built-in tool calls.

    A transcript header shows a verb and the call's salient input, for example
    [Read(lib/tui/app.ml)] or [Search("notice_block" in lib/tui)]. {!headline}
    projects that salient argument from the durable call input. It owns every
    per-tool projection rule so a renderer never reimplements a tool's private
    input decoder or guesses a common JSON member.

    The projection reads members by name from the raw input JSON. It never
    raises: input that is not the expected object shape, or a built-in whose
    salient members are absent, yields [None]. It never guesses for a tool it
    does not know, so an unknown extension always yields [None]. *)

val headline : tool:string -> input:Jsont.json -> string option
(** [headline ~tool ~input] is the salient one-row display argument for a call
    to the built-in [tool] with decoded JSON [input], or [None] when there is no
    such argument.

    The result is a single presentation string: free-text patterns and queries
    are quoted, a pattern and its search roots join as ["pat" in path], and a
    rename shows [location \u{2192} new_name]. An over-long projection is
    clipped to a bounded prefix marked with an ellipsis; the consumer still
    normalizes and width-truncates it.

    Per-tool projections, by exact tool name:

    - [read_file], [edit_file], [write_file], [ocaml_ast_edit]: the [path].
    - [search_text], [ocaml_search_expressions]: the quoted [pattern], joined
      with its [paths] as ["pattern" in a, b] when [paths] is present.
    - [glob]: the [pattern], joined with its optional [path] as
      [pattern in path].
    - [shell]: the [command].
    - [shell_output], [shell_kill]: the background [handle].
    - [web_fetch]: the [url].
    - [web_search]: the quoted [query].
    - [ocaml_replace_expressions]: [pattern \u{2192} template].
    - [ocaml_rename]: [path:line:column \u{2192} new_name], degrading to the
      available part when a coordinate or the new name is absent.
    - [ocaml_eval]: the [code].
    - [ocaml_docs]: the [query].
    - [ocaml_type_at], [ocaml_find_references]: [path:line:column].
    - [ocaml_find_definitions]: the [identifier] when present, else
      [path:line:column].
    - [skill]: the skill [name].
    - [spawn]: the [description] when present, else the [task].
    - [wait]: the waited-for [children], comma-joined.
    - [send]: the recipient handle [to].
    - [follow_up] (and the retired [send_message] spelling, which recorded
      calls in old journals still carry): the recipient [child].

    [None] is returned for:

    - [apply_patch]: its affected paths live inside the patch envelope, whose
      format the patch decoder owns; no input member carries them.
    - [todo_write], [propose_plan], [ask_user]: their content renders from their
      own facts, not the call header.
    - any unknown extension tool. *)
