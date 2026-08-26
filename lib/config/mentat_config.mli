(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The pure core of host configuration: field vocabulary, parsing, layered
    precedence, and edit planning.

    Everything a caller can learn about configuration here is a
    {e function of values}. The library links no effect library, so
    {b configuration cannot touch disk} is a compiler fact.

    {1:model The model}

    Three concepts carry the whole surface:

    - A {{!Field.t}field} is a typed handle for one supported setting. Its first
      type parameter is the setting's domain value ({!Field.model} is a
      [Mentat_provider.Selector.t] field, {!Field.sandbox_mode} a {!Mode.t}
      field); its second records whether the field has a built-in default
      ({{!Field.defaulted}[defaulted]}) or resolves to an optional value
      ({{!Field.optional}[optional]}). Fields drive string-addressed editing,
      typed reads and writes, provenance, and enumeration.
    - A {{!type:t}configuration} is a partial, typed assignment of supported
      fields plus the structured [permission.rules]. One value of this type is
      one config file's supported contents {e or} one caller-supplied runtime
      override layer — the treatment (allowlists, trust gating) is decided by
      the position a configuration is handed to {!resolve} in, not by its type.
      Files parse to it ({!of_text}), programs build it ({!set}), raw CLI text
      enters through {!set_text}, and {!plan} splices it back into a file's
      bytes while preserving ordinary unknown members.
    - A {{!Resolved.t}resolved configuration} is the effective assignment after
      {!resolve} merges every layer, applies built-in defaults, and sanitizes
      untrusted workspace input. {!Resolved.get} reads a defaulted field
      totally; {!Resolved.find} reads any field optionally; {!Resolved.origin}
      and {!Resolved.warnings} report provenance and dropped inputs.

    {1:boundaries What this library is not}

    Four responsibilities the surrounding system deliberately keeps out of the
    pure core, each with its owner:

    - {b No discovery, no IO.} File location, byte-capped reads, atomic writes,
      parent-directory creation, [.gitignore] maintenance, and cross-process
      locks belong to the {e executable}. It reads bytes, calls this core to
      parse and to plan, and performs the write a {!Plan.t} describes.
    - {b No trust decision.} Whether a workspace is trusted is read from the
      trust store by the {e executable} and handed to {!resolve} as a
      pre-decided {!type:workspace_config} variant. The trust-{e gated}
      reduction that follows — dropping non-allowlist keys, stripping
      [permission.rules], and clamping a widening [run.max_steps], each with a
      warning — is a pure law and lives here.
    - {b No posture composition.} Composing the durable
      {!Resolved.permission_rules} and [permission.unattended] value with the
      fixed product policy and session grants into a run posture is the
      {e engine}'s job at turn-contract resolution. Config reports only the
      durable configuration facts.
    - {b No environment acquisition.} {e Interpreting} an environment variable
      is config vocabulary and lives here; {e snapshotting} the process
      environment is IO. {!resolve} takes the snapshot as an [env] getter.

    {1:read_write The read and write paths}

    {b Reading.} {!resolve} takes already-read configurations and a pre-decided
    trust outcome and returns a {!Resolved.t}. Read effective values with the
    typed {!Resolved.get} and {!Resolved.find}, the textual projection with
    {!Resolved.text}, provenance with {!Resolved.origin}, and non-fatal facts
    with {!Resolved.warnings}.

    {b Writing.} An edit is planned, never performed: {!plan} applies a caller's
    transformation to a file's supported fields and returns {!Plan.Unchanged} or
    {!Plan.Write} carrying the exact bytes to persist. The executable performs
    the atomic write. Ordinary unknown config-file fields survive an edit
    untouched, but they are not part of the read API. *)

(** {1:errors Errors} *)

module Error : sig
  type t
  (** The type for recoverable configuration errors.

      Errors cover JSON decoding, invalid JSON shapes for supported fields,
      invalid typed values, and invalid config keys. Error messages never
      contain credential material. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic.

      Messages are intended for users and tests, not for stable storage. *)

  val diagnostic : t -> Mentat_diagnostic.t
  (** [diagnostic e] is [e] as a renderable boundary diagnostic. Multi-line
      decoder traces are rendered as diagnostic context under a single-line
      primary message. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e]'s message for diagnostics. *)
end

(** {1:origins Sources and origins} *)

module Source : sig
  (** Configuration value sources.

      [User], [Project], [Project_local], and [Extra_file] identify file layers.
      [Env] identifies one process-environment variable. [Override] identifies
      caller-supplied runtime layers. [Default] identifies built-in or
      platform-derived values such as [shell]. *)

  type t =
    | User of { path : Lpath.Abs.t }  (** A user config file at [path]. *)
    | Project of { path : Lpath.Abs.t }
        (** A shared project config file at [path]. *)
    | Project_local of { path : Lpath.Abs.t }
        (** A gitignored project-local config file at [path]. *)
    | Extra_file of { path : Lpath.Abs.t }
        (** An extra config file at [path], selected explicitly or by
            [MENTAT_CONFIG]. *)
    | Env of { name : string }
        (** A process-environment override named [name]. *)
    | Override  (** A caller-supplied runtime override layer. *)
    | Default of { reason : string }
        (** A built-in or platform-derived default with diagnostic [reason]. *)

  val kind_string : t -> string
  (** [kind_string t] is the stable short source kind used in user-facing
      provenance: ["user"], ["project"], ["project-local"], ["extra"], ["env"],
      ["override"], or ["default"]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps sources to credential-free diagnostic JSON.

      The codec is intended for diagnostics, not for config-file storage. *)
end

module Origin : sig
  (** Provenance of one effective config value. *)

  type t
  (** The type for effective value provenance.

      Provenance records the highest-precedence configured source and the
      lower-precedence configured sources that it shadowed. *)

  val source : t -> Source.t
  (** [source t] is the winning source for the effective value. *)

  val shadowed : t -> Source.t list
  (** [shadowed t] are lower-precedence sources that also configured the value,
      ordered from nearest shadowed source to lowest precedence. Built-in
      defaults are never shadowed values. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps origins to credential-free diagnostic JSON. *)
end

(** {1:enums Product value vocabulary}

    The closed enums whose domain values are config's own product vocabulary
    rather than a foundation type. Their spellings and ordering are the values
    the matching fields accept. *)

module Mode : sig
  (** Product sandbox modes selected by CLI and config.

      The values of the [sandbox.mode] field. The sandbox foundation
      ([mentat.sandbox]) models the {e policy algebra} a mode lowers to; the
      mode vocabulary itself is product posture owned here. *)

  type t = Read_only | Workspace_write | Danger_full_access | External_sandbox

  val all : t list
  (** [all] are the modes in declaration order. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s config spelling, for example ["workspace-write"].
  *)

  val of_string : string -> t option
  (** [of_string s] is the mode spelled [s], or [None] for an unknown spelling.
  *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same mode. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s spelling. *)
end

module Dune_watch : sig
  (** Build-watch posture.

      The values of the [dune.watch] field. *)

  type t = Auto | Observe | Off

  val all : t list
  (** [all] are the postures in declaration order. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s config spelling, for example ["observe"]. *)

  val of_string : string -> t option
  (** [of_string s] is the posture spelled [s], or [None] for an unknown
      spelling. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same posture. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s spelling. *)
end

module Read : sig
  (** Filesystem read scope for confined commands.

      The values of the [sandbox.read] field. *)

  type t = Project | All

  val all : t list
  (** [all] are the read scopes in declaration order. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s config spelling, ["project"] or ["all"]. *)

  val of_string : string -> t option
  (** [of_string s] is the read scope spelled [s], or [None]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same scope. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s spelling. *)
end

module Env_inherit : sig
  (** Child-environment inheritance posture for confined commands.

      The values of the [sandbox.env_inherit] field. *)

  type t =
    | Allowlist  (** The curated allow-list alone — the default. *)
    | All
        (** Additionally inherit every remaining ambient variable that survives
            the built-in floor and the exclude/include_only policy. *)

  val all : t list
  (** [all] are the postures in declaration order. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s config spelling, ["allowlist"] or ["all"]. *)

  val of_string : string -> t option
  (** [of_string s] is the posture spelled [s], or [None]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same posture. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s spelling. *)
end

module Notify : sig
  (** Notification vocabulary for the [notify.*] fields.

      The fields store validated spellings ({!Field.notify_channel},
      {!Field.notify_when}, {!Field.notify_on}); a consumer reads the typed
      enums back with [of_string], so the TUI reducer decides the notification
      policy against these shared enums without a private sum type. *)

  module Channel : sig
    (** A notification delivery channel. [Auto] resolves to bell plus OSC 9 for
        a graceful default; [Command] runs the configured external hook. *)
    type t = Off | Bell | Osc9 | Osc777 | Auto | Command

    val all : t list

    val values : string list
    (** [values] are the accepted spellings, in {!all} order. *)

    val to_string : t -> string
    val of_string : string -> t option
    val equal : t -> t -> bool
    val pp : Format.formatter -> t -> unit
  end

  module When : sig
    (** When notifications fire relative to terminal focus. *)
    type t = Unfocused | Always

    val all : t list
    val values : string list
    val to_string : t -> string
    val of_string : string -> t option
    val equal : t -> t -> bool
    val pp : Format.formatter -> t -> unit
  end

  module Event : sig
    (** The events that can raise a notification. *)
    type t = Turn_done | Decision

    val all : t list
    val values : string list
    val to_string : t -> string
    val of_string : string -> t option
    val equal : t -> t -> bool
    val pp : Format.formatter -> t -> unit
  end
end

(** {1:fields Fields} *)

module Field : sig
  (** Supported config fields.

      A field is a typed handle for one supported setting. The first type
      parameter is the setting's domain value: {!run_max_steps} is an [int]
      field and {!reasoning} a [Mentat_llm.Request.Options.Reasoning_effort.t]
      field. The second is the field's {e defaultedness}: a
      {{!defaulted}[defaulted]} field always resolves to a value (its built-in
      default when unconfigured), so {!Resolved.get} reads it totally; an
      {{!optional}[optional]} field has no built-in default and resolves through
      {!Resolved.find}.

      Two closed-vocabulary fields, [tools.editor] and [workspace.tooling], are
      [string] fields: their codecs accept only a fixed set of spellings, but
      the domain value stays a validated string with no dedicated type. *)

  type defaulted
  (** Witness of a field with a built-in default. Values of this type are never
      constructed; it indexes {!type:t}. *)

  type optional
  (** Witness of a field without a built-in default. Values of this type are
      never constructed; it indexes {!type:t}. *)

  type ('a, 'd) t
  (** The type for one supported config field reading a domain value of type
      ['a], with defaultedness ['d] ({!defaulted} or {!optional}). *)

  type any =
    | Any : ('a, 'd) t -> any
        (** The type for a field of unknown domain type. Surfaces that enumerate
            or parse fields — {!all}, {!of_string}, {!Resolved.origins} — carry
            them as [any]. *)

  (** {2:vals The fields} *)

  val model : (Mentat_provider.Selector.t, optional) t
  (** [model] is the [model] field, a [provider/model] selector. *)

  val small_model : (Mentat_provider.Selector.t, optional) t
  (** [small_model] is the [small_model] field, a [provider/model] selector for
      the auxiliary small-model role (session auto-titling and other cheap side
      calls). Like {!model} it is a workspace-shared selector; when it is unset
      or its model is unavailable the small role falls back to the resolved main
      model, so it never blocks a run. *)

  val reasoning : (Mentat_llm.Request.Options.Reasoning_effort.t, optional) t
  (** [reasoning] is the [reasoning] field. *)

  val tui_thinking : (bool, defaulted) t
  (** [tui_thinking] is the [tui.thinking] field. Defaults to [true]. *)

  val tui_mouse : (bool, defaulted) t
  (** [tui_mouse] is the [tui.mouse] field, enabling terminal mouse capture in
      the TUI. Defaults to [true]; the [MENTAT_DISABLE_MOUSE] environment
      variable, when set to a non-empty value, flips the default to [false]. An
      explicit configured value still overrides that env-derived default. *)

  val notify_enabled : (bool, defaulted) t
  (** [notify_enabled] is the [notify.enabled] field. Defaults to [true]. *)

  val notify_channel : (string, defaulted) t
  (** [notify_channel] is the [notify.channel] field, one of
      {!Notify.Channel.values}. Defaults to ["auto"] (bell plus OSC 9). Read the
      typed channel with {!Notify.Channel.of_string}. *)

  val notify_when : (string, defaulted) t
  (** [notify_when] is the [notify.when] field, one of {!Notify.When.values}.
      Defaults to ["unfocused"]. *)

  val notify_command : (string list, defaulted) t
  (** [notify_command] is the [notify.command] field: the argv prefix for the
      [command] channel, to which the event kind, session title, and message are
      appended. Defaults to [[]]. *)

  val notify_on : (string list, defaulted) t
  (** [notify_on] is the [notify.on] field: the subset of {!Notify.Event.values}
      that raises a notification. Defaults to every event. *)

  val tui_theme : (string, defaulted) t
  (** [tui_theme] is the [tui.theme] field: a built-in theme name or a user
      theme file basename. Defaults to ["mentat-dark"] (the Melange brand
      identity); the retired name ["mentat"] is accepted as a hidden alias for
      one release. ["auto"] follows the terminal's light/dark colour scheme,
      picking between {!tui_theme_dark} and {!tui_theme_light}. *)

  val tui_theme_dark : (string, defaulted) t
  (** [tui_theme_dark] is the [tui.theme_dark] field: the theme
      [tui.theme = "auto"] selects when the terminal reports a dark colour
      scheme (and the startup fallback until it answers). Defaults to
      ["mentat-dark"]. Ignored unless [tui.theme = "auto"]. *)

  val tui_theme_light : (string, defaulted) t
  (** [tui_theme_light] is the [tui.theme_light] field: the theme
      [tui.theme = "auto"] selects when the terminal reports a light colour
      scheme. Defaults to ["mentat-light"]. Ignored unless [tui.theme = "auto"].
  *)

  val tui_diff_layout : (string, defaulted) t
  (** [tui_diff_layout] is the [tui.diff_layout] field: the review diff's layout
      policy, one of [auto], [unified], or [split]. Defaults to ["auto"]
      (side-by-side once the diff pane is wide enough, else stacked). *)

  val provider_base_url : Mentat_llm.Provider.t -> (string, optional) t
  (** [provider_base_url provider] is the [providers.<provider>.base_url] field.
  *)

  val run_max_steps : (int, optional) t
  (** [run_max_steps] is the [run.max_steps] field. *)

  val run_subagent_max_concurrent : (int, defaulted) t
  (** [run_subagent_max_concurrent] is the [run.subagent_max_concurrent] field:
      the cap on concurrently running subagent children over a session tree.
      Defaults to [4]; it is also the provider fan-out bound. *)

  val run_subagent_max_depth : (int, defaulted) t
  (** [run_subagent_max_depth] is the [run.subagent_max_depth] field: the
      deepest child a spawn may create; root children are depth [1]. Defaults to
      [2]. *)

  val run_subagent_max_exchanges : (int, defaulted) t
  (** [run_subagent_max_exchanges] is the [run.subagent_max_exchanges] field:
      the per-run cap on parent<->child message exchanges (messages sent plus
      asks parked). Model-origin sends over the cap fail; asks over the cap park
      with the cap as blocker; user-origin sends are exempt. Defaults to [8]. *)

  val permission_unattended : (Mentat_permission.Unattended.t, defaulted) t
  (** [permission_unattended] is the [permission.unattended] field. Defaults to
      {!Mentat_permission.Unattended.Block}. *)

  val sandbox_mode : (Mode.t, optional) t
  (** [sandbox_mode] is the [sandbox.mode] field. It has no built-in default: an
      unset mode resolves through the host sandbox adapter, or fails fast. *)

  val sandbox_require : (Mentat_sandbox.Requirement.t, defaulted) t
  (** [sandbox_require] is the [sandbox.require] field. Defaults to [Enforced].
  *)

  val sandbox_read : (Read.t, defaulted) t
  (** [sandbox_read] is the [sandbox.read] field. Defaults to {!Read.Project}.
  *)

  val sandbox_readable_roots : (string list, defaulted) t
  (** [sandbox_readable_roots] is the [sandbox.readable_roots] field: additional
      read roots used by {!Read.Project}, as raw path spellings — absolute, [~],
      or [~/...]. The host sandbox resolver expands and physically resolves
      them. Defaults to [[]]. *)

  val sandbox_writable_roots : (string list, defaulted) t
  (** [sandbox_writable_roots] is the [sandbox.writable_roots] field: extra
      writable roots for workspace-write, as raw path spellings — absolute, [~],
      or [~/...]. The host sandbox resolver tilde-expands and canonicalizes
      them. Defaults to [[]]. *)

  val sandbox_network : (Mentat_sandbox.Policy.Network.t, defaulted) t
  (** [sandbox_network] is the [sandbox.network] field. Defaults to
      [Restricted]. *)

  val sandbox_env_inherit : (Env_inherit.t, defaulted) t
  (** [sandbox_env_inherit] is the [sandbox.env_inherit] field:
      {!Env_inherit.Allowlist} (the default) constructs the child environment
      from the curated allow-list alone; {!Env_inherit.All} additionally
      inherits every remaining ambient variable that survives the built-in floor
      — the secret-shaped name patterns and agent handles, which no setting
      subtracts from — and the exclude/include_only policy below. *)

  val sandbox_env_exclude : (string list, defaulted) t
  (** [sandbox_env_exclude] is the [sandbox.env_exclude] field: case-insensitive
      [*] globs removed from the inheritable sets, on top of the built-in floor.
      The structural core — [PATH], [HOME], the temp-dir family and the base
      directories the sandbox derives roots from — is not excludable: the policy
      grants what the child computes, and the two may not disagree. Defaults to
      [[]]. *)

  val sandbox_env_include_only : (string list, defaulted) t
  (** [sandbox_env_include_only] is the [sandbox.env_include_only] field: when
      non-empty, only inheritable variables matching one of these globs reach
      the child (the structural core always does). Defaults to [[]]. *)

  val shell : (string, defaulted) t
  (** [shell] is the [shell] field: the shell executable used for shell
      commands. Defaults to the platform shell ([SHELL], or [COMSPEC] on
      Windows). *)

  val compaction_auto : (bool, defaulted) t
  (** [compaction_auto] is the [compaction.auto] field. Defaults to [true]. *)

  val revert_merge : (bool, defaulted) t
  (** [revert_merge] is the [revert.merge] field: whether a revert of a
      superseded selection three-way merges rather than refusing. Defaults to
      [true]. *)

  val notices_fswatch : (bool, defaulted) t
  (** [notices_fswatch] is the [notices.fswatch] field. Defaults to [true]. *)

  val notices_cr_comments : (bool, defaulted) t
  (** [notices_cr_comments] is the [notices.cr_comments] field. Defaults to
      [true]. *)

  val notices_dune_diagnostics : (bool, defaulted) t
  (** [notices_dune_diagnostics] is the [notices.dune_diagnostics] field.
      It silences the model's build-change notices only; the watch itself,
      its status row, and its lifecycle advisories — a restart, a blocked
      file watcher — are [dune.watch]'s and still surface. Defaults to
      [true]. *)

  val dune_watch : (Dune_watch.t, defaulted) t
  (** [dune_watch] is the [dune.watch] field: [auto], [observe], or [off].
      [auto] attaches to an already-running build watch, or starts and
      supervises one when nothing answers; [observe] only attaches, never
      starts; [off] disables the watch integration entirely. Under a
      read-only sandbox posture [auto] behaves as [observe] — a watch that
      could not write [_build] would only die at startup. Defaults to
      ["auto"]. *)

  val dune_targets : (string list, defaulted) t
  (** [dune_targets] is the [dune.targets] field: the targets a started build
      watch builds, each passed verbatim after [dune build --watch] — entries
      are targets, never dune flags, and a leading dash is refused. An empty
      list builds dune's default target set ([@default]), usually a far
      heavier watch than the default [["@check"]]. *)

  val dune_lint_command : (string list, defaulted) t
  (** [dune_lint_command] is the [dune.lint_command] field: the linter's
      argv prefix, run from the workspace root after each green build settle
      — the moment the build artifacts it reads are fresh. [[]] disables the
      runner; a command whose program does not resolve on the sealed command
      PATH leaves the lint lane off for the session. Defaults to
      [["litany"; "check"]] — a default, not a coupling: any linter printing
      compiler-shaped diagnostics fits. *)

  val workspace_tooling : (string, defaulted) t
  (** [workspace_tooling] is the [workspace.tooling] field: [auto], [on], or
      [off]. It gates the workspace's OCaml/Dune integration as a whole.
      Defaults to ["auto"]; resolving [auto] for a given root probes the
      filesystem and is therefore an executable-owned operation. *)

  val instructions_global : (bool, defaulted) t
  (** [instructions_global] is the [instructions.global] field. Defaults to
      [true]. *)

  val instructions_project : (bool, defaulted) t
  (** [instructions_project] is the [instructions.project] field. Defaults to
      [true]. *)

  val instructions_claude_md : (bool, defaulted) t
  (** [instructions_claude_md] is the [instructions.claude_md] field. Defaults
      to [true]. *)

  val instructions_project_max_bytes : (int, defaulted) t
  (** [instructions_project_max_bytes] is the [instructions.project_max_bytes]
      field: the byte budget for project instruction content. *)

  val skills_enabled : (bool, defaulted) t
  (** [skills_enabled] is the [skills.enabled] field. Defaults to [true]. *)

  val skills_builtin : (bool, defaulted) t
  (** [skills_builtin] is the [skills.builtin] field. Defaults to [true]. *)

  val skills_project : (bool, defaulted) t
  (** [skills_project] is the [skills.project] field. Defaults to [true]. *)

  val skills_compat : (bool, defaulted) t
  (** [skills_compat] is the [skills.compat] field. Defaults to [true]. *)

  val skills_disabled : (string list, defaulted) t
  (** [skills_disabled] is the [skills.disabled] field: skill names excluded
      from the catalog and its budget, whatever root they were found in. Unknown
      names are inert but preserved. Defaults to [[]]. *)

  val skills_paths : (string list, defaulted) t
  (** [skills_paths] is the [skills.paths] field: additional skill search roots.
      Defaults to [[]]. *)

  val skills_catalog_max_bytes : (int, defaulted) t
  (** [skills_catalog_max_bytes] is the [skills.catalog_max_bytes] field: the
      byte budget for rendered skill catalog text. *)

  val commands_enabled : (bool, defaulted) t
  (** [commands_enabled] is the [commands.enabled] field. Master switch for
      user-invoked custom commands; off ⇒ empty catalog. Defaults to [true]. *)

  val commands_project : (bool, defaulted) t
  (** [commands_project] is the [commands.project] field: gate the three project
      command roots ([.mentat], [.agents], [.claude]). Defaults to [true]. *)

  val commands_compat : (bool, defaulted) t
  (** [commands_compat] is the [commands.compat] field: gate the [.agents] and
      [.claude] compatibility command roots only. Defaults to [true]. *)

  val commands_disabled : (string list, defaulted) t
  (** [commands_disabled] is the [commands.disabled] field: command names
      excluded before shadowing, whatever root they were found in. Unknown names
      are inert but preserved. Defaults to [[]]. *)

  val tools_editor : (string, defaulted) t
  (** [tools_editor] is the [tools.editor] field, an enum spelled ["auto"],
      ["apply-patch"], or ["string-replace"]. ["auto"] (the default) lets the
      host pick the editor family from the model's capabilities; the other two
      force it. *)

  val ocaml_merlin_program : (string list, defaulted) t
  (** [ocaml_merlin_program] is the [ocaml.merlin_program] field, a non-empty
      argv prefix of non-empty tokens. Defaults to [["ocamlmerlin"]]; the host
      resolves it to a lock-free argv once at boot. *)

  val web_enabled : (bool, defaulted) t
  (** [web_enabled] is the [web.enabled] field. Defaults to [false]. *)

  val web_allow_private_network : (bool, defaulted) t
  (** [web_allow_private_network] is the [web.allow_private_network] field.
      Defaults to [false]. *)

  val web_fetch_max_bytes : (int, defaulted) t
  (** [web_fetch_max_bytes] is the [web.fetch_max_bytes] field: the maximum
      response body size fetched by web tools, in bytes. It is user-owned;
      workspace layers cannot set it. *)

  val web_output_max_chars : (int, defaulted) t
  (** [web_output_max_chars] is the [web.output_max_chars] field: the maximum
      text output returned to the model, in characters. It is user-owned;
      workspace layers cannot set it. *)

  val web_timeout_ms : (int, defaulted) t
  (** [web_timeout_ms] is the [web.timeout_ms] field: the default web request
      timeout in milliseconds. It is user-owned; workspace layers cannot set it.
  *)

  val web_max_timeout_ms : (int, defaulted) t
  (** [web_max_timeout_ms] is the [web.max_timeout_ms] field: the maximum
      caller-selectable web request timeout in milliseconds. It is user-owned;
      workspace layers cannot set it. *)

  val web_search_provider : (string, defaulted) t
  (** [web_search_provider] is the [web.search_provider] field, an enum spelled
      ["exa"], ["parallel"], or ["off"]. It selects the backend the [web_search]
      tool posts to — both are keyless-capable remote MCP search endpoints — or
      ["off"] to withhold the tool even when [web.enabled]. Defaults to ["exa"].
  *)

  val web_exa_api_key : (string, optional) t
  (** [web_exa_api_key] is the [web.exa_api_key] field: an optional Exa API key.
      Exa search works keyless; a key raises rate and access limits. It is
      secret-bearing — its value is withheld from the values-with-origins view —
      and is read from the config file or [MENTAT_EXA_API_KEY]. It is
      user-owned; workspace layers cannot set it. *)

  val web_parallel_api_key : (string, optional) t
  (** [web_parallel_api_key] is the [web.parallel_api_key] field: an optional
      Parallel API key. Parallel search works keyless; a key raises rate and
      access limits. It is secret-bearing — its value is withheld from the
      values-with-origins view — and is read from the config file or
      [MENTAT_PARALLEL_API_KEY]. It is user-owned; workspace layers cannot set
      it. *)

  val image_max_bytes : (int, defaulted) t
  (** [image_max_bytes] is the [image.max_bytes] field: the maximum decoded
      (pre-base64) size of an attached or read image, in bytes. This is the
      binding cap; an oversized image is downscaled toward it before rejection.
      Defaults to 5 MiB. *)

  val image_max_dimension : (int, defaulted) t
  (** [image_max_dimension] is the [image.max_dimension] field: the maximum
      pixels per side of an image, a decompression-bomb ceiling rather than the
      binding cap. Defaults to 8000. *)

  val image_max_count : (int, defaulted) t
  (** [image_max_count] is the [image.max_count] field: the maximum number of
      images in a single input. Defaults to 20. *)

  (** {2:support Naming, parsing, and enumeration} *)

  val name : ('a, 'd) t -> string
  (** [name field] is [field]'s stable config-file spelling. *)

  val of_string : string -> (any, Error.t) result
  (** [of_string s] parses a supported config-file field. Errors carry
      did-you-mean hints and the supported-key list. *)

  val equal : ('a, 'd) t -> ('b, 'e) t -> bool
  (** [equal a b] is [true] iff [a] and [b] name the same field. *)

  val all : any list
  (** [all] is the finite list of non-provider-family fields in stable order.

      Provider base URL keys are a family and are parsed by {!of_string}; they
      are not enumerable without a provider id. *)

  val values : ('a, 'd) t -> string list option
  (** [values field] is the finite set of spellings [field] accepts when its
      parser recognizes only a closed vocabulary, in presentation order, and
      [None] when [field] parses an open shape (free strings, model selectors,
      shells, paths, integers, and free lists) whose values are not enumerable.

      The closed-vocabulary fields are the enums — [reasoning],
      [permission.unattended], [sandbox.mode], [sandbox.require],
      [sandbox.read], [sandbox.network], [tools.editor], and [workspace.tooling]
      — and every boolean field, whose values are [["true"; "false"]]. The list
      is exactly the vocabulary {!set}, {!set_text}, and the file decoder
      accept, so a value drawn from it always validates. *)

  val allowed_in_workspace : ('a, 'd) t -> bool
  (** [allowed_in_workspace field] is [true] iff [field] is safe in a workspace
      config layer. The executable owns the concrete file-layer choice. *)
end

(** {1:configs Configurations} *)

type t
(** The type for one configuration layer: a partial, typed assignment of
    supported fields plus the structured [permission.rules].

    A configuration is one config file's supported contents or one
    caller-supplied runtime override; fields absent from it do not affect
    lower-precedence layers during resolution. Ordinary unknown fields from a
    source file are not in a configuration — they are preserved in place by
    {!plan}. *)

val empty : t
(** [empty] contains no configured fields and no permission rules. *)

val of_json : source:string -> Jsont.json -> (t, Error.t) result
(** [of_json ~source json] decodes [json]'s supported fields into a
    configuration. Ordinary unknown fields are ignored, whether or not they name
    a shape a previous release supported: an unsupported member such as
    [permission.mode], [run.subagent_wake], [tools.anchored_edits], or
    [web.search_backend] has no {!Field.t}, scalar alias, or decoder, and so is
    ignored on load and preserved by {!plan} like any other unknown field.

    [source] labels shape and value errors — the file whose contents [json] are
    — so a load error reads ["<source> run.max_steps must be an integer"]; the
    executable passes the concrete file path. *)

val of_text : source:string -> string -> (t, Error.t) result
(** [of_text ~source text] decodes [text] as JSON and then as a configuration.

    Ordinary unknown members behave exactly as in {!of_json}.

    The empty string decodes to {!empty} — an absent or 0-byte file, which the
    caller passes as [""]. This is a deliberate seam: a load path that decoded
    the raw bytes of a 0-byte file would error, whereas [of_text ""] is the
    empty configuration. [source] labels errors as in {!of_json}. *)

(** {2:queries Queries} *)

val find : ('a, 'd) Field.t -> t -> 'a option
(** [find field c] is [field]'s domain value in [c], if configured. Built-in
    defaults are not consulted: a configuration is an assignment, not an
    effective view (that is {!Resolved.t}). *)

val text : ('a, 'd) Field.t -> t -> string option
(** [text field c] is [field]'s textual value in [c], if configured. The
    spelling round-trips through {!set_text}. *)

val permission_rules : t -> Mentat_permission.Policy.Rule.t list
(** [permission_rules c] are [c]'s durable permission rules in file order.

    The config wire form is a version-1 object containing an [items] array of
    {!Mentat_permission.Policy.Rule.jsont} values. Unknown versions and the
    obsolete bare-array form fail when the configuration is decoded. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] hold the same supported fields and the
    same permission rules. *)

(** {2:updates Updates}

    Updates validate the field's invariant and are otherwise pure functional
    updates. Parse errors exist only where raw text enters ({!set_text}); {!set}
    can still error when the domain type is weaker than the field's invariant —
    for example, an [int] field must be positive. Selector syntax is already
    carried by [Mentat_provider.Selector.t]. *)

val set : ('a, 'd) Field.t -> 'a -> t -> (t, Error.t) result
(** [set field value c] is [c] with [field] bound to [value].

    Errors when [value] violates [field]'s invariant:
    - provider base URLs, [shell], and every plain string must be non-empty;
    - every integer field must be positive and within JSON's exact integer
      range;
    - closed-vocabulary string fields ([tools.editor], [workspace.tooling])
      accept only their {!Field.values} spellings;
    - list elements must be non-empty; the sandbox roots must each be absolute,
      ["~"], or start with ["~/"]; [ocaml.merlin_program] must be a non-empty
      argv of NUL-free tokens.

    Fields whose domain type already carries the invariant (booleans and the
    dedicated enums) never error. *)

val set_text : ('a, 'd) Field.t -> string -> t -> (t, Error.t) result
(** [set_text field raw c] is [c] with [field] bound to the value [raw] parses
    to with [field]'s textual parser — the entry point for raw CLI text.

    List fields ([sandbox.readable_roots], [sandbox.writable_roots],
    [skills.paths], [skills.disabled], [ocaml.merlin_program]) take a JSON array
    of strings; no other JSON syntax is interpreted — a plain string field
    receives [raw] verbatim. Values then validate as in {!set}. *)

val unset : ('a, 'd) Field.t -> t -> t
(** [unset field c] is [c] without a binding for [field]. *)

val set_permission_rules : Mentat_permission.Policy.Rule.t list -> t -> t
(** [set_permission_rules rules c] replaces [c]'s durable permission rules. An
    empty list removes the field. *)

(** {1:planning Validation and edit planning} *)

val validate : source:string -> Jsont.json -> Error.t list
(** [validate ~source json] collects every shape or value error in [json]'s
    supported fields, labelling each with [source].

    A member no field spells is not an error: the file format tolerates unknown
    members so an edit preserves them across versions. {!ignored_keys} reports
    those separately. *)

val ignored_keys :
  ?workspace:bool -> source:string -> Jsont.json -> Error.t list
(** [ignored_keys ~source json] is every key [json] carries that has no effect,
    in file order, each labelled with [source]: members no field spells,
    including unknown members of a known section or of a [providers] entry.

    [workspace] declares [json] a workspace layer ([.mentat/config.json] or
    [.mentat/config.local.json]), adding the supported keys the shared allowlist
    drops there and workspace [permission.rules] — text a workspace file may
    carry and {!resolve} will not read.

    These are diagnostics about inert text, not value errors; a caller decides
    whether they fail a check. *)

module Plan : sig
  (** A planned config-file edit.

      A plan is a pure value describing an edit, never a write. The executable
      performs the write. *)

  type t =
    | Unchanged  (** The transformation left the supported fields untouched. *)
    | Write of string
        (** The exact newline-terminated bytes to persist atomically. *)
end

val plan :
  source:string ->
  original:string ->
  f:(t -> (t, Error.t) result) ->
  (Plan.t, Error.t) result
(** [plan ~source ~original ~f] plans the edit that applies [f] to [original]'s
    supported fields.

    [original] is the file's current bytes. The empty string is an absent file:
    it scaffolds a minimal object, so [plan ~original:"" …] never fails on a
    missing file. This is a deliberate seam — a caller reading a 0-byte file
    passes [""] and gets the empty configuration, where a load path that decoded
    the raw bytes would error. [source] labels shape and value errors from a
    malformed [original] as in {!of_json}.

    The supported fields are decoded, [f] is applied, and if the result differs
    the new supported fields are spliced back into [original]'s JSON; supported
    empty containers are removed and provider families are written in provider
    order. The result is {!Plan.Unchanged} when [f] left the supported fields
    unchanged, or {!Plan.Write} carrying the exact newline-terminated bytes to
    persist.

    {b Ordinary unknown-field preservation is a pure law.} [original] is the
    sole authority for ordinary unknown members; the transformed configuration
    is the sole authority for supported fields. An ordinary unknown member keeps
    its {e value} and its {e nesting} across any edit — planning a [model]
    change over

    {[
      { "unknown_key": 1, "model": "old" }
    ]}

    rewrites only [model] and preserves ["unknown_key"] with its value. Member
    {e order} is not preserved: the splice re-emits members, so the relative
    order of ordinary unknown members can change (it is not a positional
    guarantee). Because the law holds without touching the filesystem, it is
    exhaustively testable as a value transformation. *)

(** {1:warnings Warnings} *)

module Warning : sig
  (** Non-fatal configuration warnings.

      A warning is a structured fact about a dropped or degraded workspace
      config input — it is not an origin for any effective value. Warnings are
      intended for CLI support output and host diagnostics. *)

  type t
  (** A non-fatal configuration warning.

      Warnings explain host-visible config inputs that did not take effect, such
      as workspace config disabled by trust, keys outside the shared allowlist,
      stripped workspace [permission.rules], clamped budget keys, and invalid
      workspace config files. *)

  val message : t -> string
  (** [message t] is a concise human-readable message. *)

  val kind_string : t -> string
  (** [kind_string t] is [t]'s stable wire kind, one of ["ignored_project_key"],
      ["ignored_project_rules"], ["ignored_project_budget"],
      ["invalid_project_config"], or ["project_config_disabled"]. It is the
      discriminant carried by {!jsont}. *)

  val source : t -> Source.t
  (** [source t] is the config source the warning is about. *)

  val field : t -> Field.any option
  (** [field t] is the config field the warning is about, when applicable. *)

  val diagnostic : t -> Mentat_diagnostic.t
  (** [diagnostic t] is [t] as a renderable boundary diagnostic: {!message} as
      the primary line, with the source attribution (and any overflow of a
      multi-line reason) as context. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for text diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps warnings to the stable support JSON shape. *)
end

(** {1:resolved Resolved configuration} *)

module Resolved : sig
  type t
  (** The type for resolved effective configuration.

      A resolved value is a snapshot: it does not update if files or environment
      variables change. Built-in defaults are baked in at {!resolve} time (using
      its [env] getter for platform-derived values such as [shell]), so every
      read below is a pure lookup. *)

  (** {2:reads Typed reads} *)

  val get : ('a, Field.defaulted) Field.t -> t -> 'a
  (** [get field t] is [field]'s effective domain value: the highest-precedence
      configured value, or [field]'s built-in default. The {!Field.defaulted}
      index guarantees the read is total. *)

  val find : ('a, 'd) Field.t -> t -> 'a option
  (** [find field t] is [field]'s effective domain value, if any. For a
      defaulted field this is always [Some] (prefer {!get}); for an optional
      field it is the configured value or [None]. *)

  val configured : ('a, 'd) Field.t -> t -> 'a option
  (** [configured field t] is [field]'s configured domain value, if it was set
      by any layer. Built-in defaults are not applied:
      [configured Field.tui_thinking t] is [None] for an unconfigured
      [tui.thinking] even though {!get} reads [true]. *)

  (** {2:projections Textual projection} *)

  val text : ('a, 'd) Field.t -> t -> string option
  (** [text field t] is the effective textual config value named by [field], if
      it has an effective value. Resolved defaults, such as [shell], render as
      values. *)

  (** {2:provenance Provenance and facts} *)

  val origin : ('a, 'd) Field.t -> t -> Origin.t option
  (** [origin field t] is [field]'s effective provenance, if [field] has an
      effective value. Resolved defaults such as [shell] have {!Source.Default}
      origins. *)

  val origins : t -> (Field.any * Origin.t) list
  (** [origins t] are all effective value origins, ordered by config-key
      spelling. *)

  val warnings : t -> Warning.t list
  (** [warnings t] are non-fatal config warnings for [t].

      Warnings report workspace config inputs dropped at resolution: invalid or
      oversized workspace files, keys outside the shared allowlist, stripped
      [permission.rules], budget keys that tried to widen the non-workspace
      effective value. The result is ordered for stable support output. *)

  val permission_rules :
    t -> (Source.t * Mentat_permission.Policy.Rule.t list) list
  (** [permission_rules t] are durable permission-rule groups paired with their
      config source, ordered by effective policy precedence. Composing them with
      the fixed product policy and session grants into a run posture is the
      engine's job, not config's. *)

  (** {2:view Values-with-origins view} *)

  module View : sig
    (** A serializable snapshot pairing every effective field with its value and
        provenance, for the read-only configuration query.

        The view is the owner-side wire form of a {!Resolved.t}: it projects
        each effective field's key, value, JSON, and {!Origin.t} plus the
        ordered durable permission rules and {!Warning.t} list, and carries no
        other resolved state. It is {b credential-free by construction} — a
        secret-bearing field's value is withheld at projection time, never
        serialized (see {!Value.Redacted}), so no wire form can ever leak one.
        The codec is for diagnostics and display, not config-file storage. *)

    module Value : sig
      type t =
        | Shown of { text : string; json : Jsont.json }
            (** The effective value, as its textual and JSON projections. *)
        | Redacted
            (** The field is secret-bearing; its value is withheld at the owner
                and never enters the snapshot. Only the field's key and origin
                are reported. *)
    end

    module Entry : sig
      type t
      (** One effective field's key, value, and provenance. *)

      val key : t -> string
      (** [key t] is the effective field's stable config-key spelling. *)

      val value : t -> Value.t
      (** [value t] is the effective value, or {!Value.Redacted} for a
          secret-bearing field. *)

      val origin : t -> Origin.t
      (** [origin t] is the effective value's provenance. *)
    end

    module Permission_rule : sig
      (** Durable permission rules with identity and config provenance. *)

      type t
      (** One permission rule in the effective policy order.

          The row retains the exact owner rule, its content-derived typed id,
          and the non-workspace file source that contributed it. Its invariant
          is [id t = Mentat_permission.Policy.Rule.id (rule t)]. *)

      val id : t -> Mentat_permission.Policy.Rule.Id.t
      (** [id t] is the owner-derived identity of {!rule}. *)

      val rule : t -> Mentat_permission.Policy.Rule.t
      (** [rule t] is the exact durable permission rule. *)

      val source : t -> Source.t
      (** [source t] is the file provenance of [rule t]. It is either
          {!Source.User} or {!Source.Extra_file}; workspace, environment,
          default, and runtime-override sources cannot contribute durable
          permission rules. *)

      val equal : t -> t -> bool
      (** [equal a b] is [true] iff [a] and [b] carry the same typed id, exact
          rule, and source. *)

      val pp : Format.formatter -> t -> unit
      (** [pp ppf t] formats [t]'s id, source, and rule for diagnostics. The
          output is not stable storage syntax. *)

      val jsont : t Jsont.t
      (** [jsont] maps rows to strict JSON objects carrying [id], [rule], and
          [source]. Decoding rejects unknown members, an id that does not match
          the decoded rule, and a source that cannot contribute durable rules.
      *)
    end

    type t
    (** The type for a values-with-origins snapshot. *)

    val entries : t -> Entry.t list
    (** [entries t] are the per-field entries, ordered by config-key spelling,
        one per effective field. *)

    val permission_rules : t -> Permission_rule.t list
    (** [permission_rules t] are the durable rule rows in effective first-match
        order: higher-precedence sources first and file order within each
        source. *)

    val warnings : t -> Warning.t list
    (** [warnings t] are the non-fatal config warnings, as {!Resolved.warnings}.
    *)

    val jsont : t Jsont.t
    (** [jsont] maps a snapshot to credential-free diagnostic JSON. Redacted
        entries carry no value member, so the codec cannot re-introduce a
        secret. Permission-rule rows retain their typed owner identity and
        provenance. Encoding then decoding round-trips the snapshot. *)
  end

  val view : t -> View.t
  (** [view t] is the serializable values-with-origins snapshot of [t]: every
      effective field paired with its value (redacted if secret-bearing) and
      origin, every durable permission rule paired with its typed identity and
      source in effective policy order, plus the warnings. This is the {e owner}
      projection the configuration query serves; redaction happens here, so no
      secret ever reaches the wire codec. *)
end

(** {1:resolution Resolution}

    {!resolve} is the read entry point. It merges already-read configurations
    and the pre-decided {!type:workspace_config} trust outcome into a
    {!Resolved.t}, performing no IO of its own. *)

(** The state of one workspace config file handed to {!resolve}, addressed by
    its path. {!resolve} mints the provenance {!Source.t} from the slot and the
    path, so callers pass file locations, not sources. *)
type workspace_file =
  | Loaded of Lpath.Abs.t * t
      (** A workspace file at this path, read and parsed by the executable. *)
  | Invalid of Lpath.Abs.t * string
      (** A workspace file at this path that could not be read or parsed, with
          the reason for a warning. *)
  | Absent  (** A workspace file that does not exist. *)

(** The trust-gated workspace-configuration input to {!resolve}. The executable
    pre-decides trust; the variant carries the outcome, never the credential
    read. *)
type workspace_config =
  | Trusted of { project : workspace_file; project_local : workspace_file }
      (** The workspace is trusted: both files participate, still passing
          through the shared-key allowlist, rule stripping, and budget clamping.
      *)
  | Disabled of {
      status : string;
      project : Lpath.Abs.t option;
      project_local : Lpath.Abs.t option;
    }
      (** The workspace is not trusted: no file contributes. [status] is the
          human-readable trust status recorded in the disabled warnings (for
          example ["untrusted"]); [project] and [project_local] are the paths of
          workspace files that exist on disk and are being ignored, [None] when
          absent. *)

val resolve :
  env:(string -> string option) ->
  user:Lpath.Abs.t * t ->
  extra:(Lpath.Abs.t * t) option ->
  workspace_config:workspace_config ->
  overrides:t list ->
  (Resolved.t, Error.t) result
(** [resolve ~env ~user ~extra ~workspace_config ~overrides] resolves effective
    configuration from already-read configurations. Every input is a value the
    executable hands in; the core performs no IO.

    [user] and [extra] pair a file path with its parsed configuration; [resolve]
    mints their provenance ({!Source.User}, {!Source.Extra_file}) from the path.

    Layers merge in increasing precedence: [user], the workspace [project] and
    [project_local] files, [extra], the environment layers built from [env] over
    each field's variable, then [overrides]. Built-in defaults contribute where
    a field is otherwise unconfigured. [user] is the user's own file and accepts
    every field, [extra] is an optional extra file ([None] for none), and
    [overrides] are the highest-precedence runtime layers ([[]] for none); none
    of these pass through the workspace reduction below. Durable permission
    rules load only from file layers: rules carried by an [overrides]
    configuration are ignored.

    {b [env] is a getter, not a map.} It supplies the process-environment
    snapshot as [string -> string option] so the pure core reads exactly the
    variables the field vocabulary names and never enumerates the process
    environment — snapshotting that is IO the executable owns. The recognized
    settings are [MENTAT_MODEL], [MENTAT_SMALL_MODEL], [MENTAT_REASONING],
    [MENTAT_MAX_STEPS], [MENTAT_PERMISSION_UNATTENDED], [MENTAT_SANDBOX_MODE],
    [MENTAT_SANDBOX_REQUIRE], [MENTAT_SANDBOX_READ], [MENTAT_SANDBOX_NETWORK],
    [MENTAT_SHELL], [MENTAT_WORKSPACE_TOOLING], [MENTAT_EXA_API_KEY],
    [MENTAT_PARALLEL_API_KEY], and the provider base URL variables; [env] also
    resolves platform-derived defaults such as [shell] (from [SHELL], or
    [COMSPEC] on Windows). Empty environment settings are ignored.

    {b [workspace_config] arrives pre-decided.} The trust decision is a
    credential-adjacent trust-store read the executable owns, so [resolve]
    receives the {e outcome} as a {!type:workspace_config} variant and applies
    only the pure, trust-gated reduction. The workspace layers activate only
    when trust is {!Trusted}: their keys reduce to the shared-key allowlist,
    [permission.rules] never load from the workspace, [run.max_steps] may
    tighten but not widen the value the non-workspace layers resolve to, and an
    {!Invalid} file degrades to an empty layer with a warning. Web resource
    limits are user-owned and therefore drop through the same non-shared-key
    path as other host policy. Every disabled, dropped, or degraded workspace
    input is reported by {!Resolved.warnings}; none of them fail resolution.

    [resolve] returns an error only when the merged non-workspace layers violate
    a cross-field invariant ([web.timeout_ms] exceeding [web.max_timeout_ms]).
*)
