# Command sandbox

The command sandbox decides what an approved tool or spawned process may
access. It does not approve the operation itself; that is
[permission policy](permissions.md).

This page covers modes, filesystem read scope, writable and protected paths,
network policy, child environments, and enforcement backends. For how the
three boundaries fit together, see [Security](security.md).

The sandbox applies to the `shell` tool, fixed-command search helpers, OCaml
tools that spawn Dune, Merlin, ocamlfind, or a toplevel, and automatic trusted
project integrations. The host resolves one posture, gates it before credential
or session effects, seals it against a platform backend, and hands command
executors the sealed spawn capability. Shell results additionally carry
evidence saying whether confinement was enforced, refused, not requested, or
declared external.

The spawn plan also owns the canonical working directory. Confined cwd must be
inside the resolved readable roots; Bubblewrap enters it after mounting the
policy, and direct process runners fork into that same directory. An invalid,
missing, or out-of-scope cwd refuses before a child starts.

Shell command facts distinguish Mentat-enforced, externally confined, and direct
execution routes. Enforced identity includes its exact read, write, and network
posture. Sandbox refusal produces no route, no permission prompt, and no child.
Project-read, restricted-network execution and explicitly selected external
boundaries receive product credit; read-all, network-enabled, and direct routes
remain reviewable. Fixed host tools do not expose their implementation argv as
command facts. Model-authored evaluator source is itself a command fact, with
its language, source, cwd, and confinement in exact permission identity. Shell
escalation is a `direct` command fact plus a separate custom access, so an
enforced command grant cannot approve dropping confinement.

## Modes

| Mode | Command behavior |
| --- | --- |
| `read-only` | Reads follow `sandbox.read`; writes are limited to shared scratch space (`/tmp` and the temp-dir variables) and network is denied. Build retains its interaction verbs, native reads/search, confined `shell`, `ocaml_eval`, enabled web fetch, and applicable non-editing OCaml tools. It omits exactly `write_file`, `edit_file`, `apply_patch`, `ocaml_ast_edit`, `ocaml_replace_expressions`, and `ocaml_rename`. Shell escalation is unavailable. |
| `workspace-write` | Reads follow `sandbox.read`. Writes are allowed only under resolved writable roots, with protected carve-outs. Network is restricted by default. |
| `danger-full-access` | Commands run without Mentat filesystem or network confinement. They still receive the exact host-constructed child environment. |
| `external-sandbox` | Mentat records that an external boundary owns confinement. Commands are not wrapped, but still receive the exact host-constructed child environment. |

The mode precedence is the `--sandbox` flag, then `sandbox.mode`, then the
built-in `workspace-write` default.

## Filesystem read scope

`sandbox.read` selects what confined commands may read:

| Value | Read behavior |
| --- | --- |
| `project` | Default. Reads are limited to the workspace, `sandbox.readable_roots`, executable search roots, OCaml toolchain roots, and the platform runtime files required to launch commands. |
| `all` | Reads may reach the host filesystem wherever ordinary filesystem permissions allow. |

Configured readable roots must be absolute or `~`-relative. They must already
exist, resolve physically, and may not name the filesystem root or the user's
home directory. The resolver reports an invalid root before the run starts;
there is no silent fallback to broader reads.

Ambient toolchain variables — `OPAM_SWITCH_PREFIX`, `OCAML_TOPLEVEL_PATH`,
`OCAMLLIB`, and similar — are recovered best-effort so a command resolves the
same toolchain it would from a login shell, and are treated more leniently than
configured roots. A value that names no usable directory — an unexpanded
placeholder such as the `%{toplevel}%` that `dune exec` leaks, a stale path, or a
file where a directory is expected — is skipped with a logged warning rather than
refused, so a launcher artifact the user never set cannot brick a run. The one
exception is a toolchain value that resolves to a broad root, which still fails
closed (below) because silently widening reads is never acceptable.

Project scope resolves physical roots once and shows their origin in
`mentat sandbox explain`. The active OPAM switch is admitted as a whole because
OCaml executables need its libraries, stublibs, findlib metadata, and sibling
tools. A linked Git worktree's `gitdir` and `commondir` are parsed without
executing Git and admitted read-only. Platform runtime roots expose some
machine facts to commands; project scope is a bounded confidentiality boundary,
not a claim that command output contains only repository text.

Broad roots fail closed: `/`, the user's home directory, and an ancestor of the
workspace cannot enter a project-scoped allowlist indirectly through config,
`PATH`, or OCaml toolchain variables. Readable roots may be files or
directories; writable roots must be directories. Requested roots must still
exist when a command starts, or the sandbox reports a stale-policy refusal.

Selecting `sandbox.read=all` makes the confined modes not confidentiality
boundaries. A confined command can then read files outside the workspace and
return their contents in tool output. Exact environment reconstruction withholds
ambient credentials, and restricted network reduces command-side exfiltration,
but neither prevents disclosure to the model. The default `project` scope, or an
external isolation boundary, preserves host-file confidentiality. If
read-anywhere is deliberate — for example with a local model — use the ordered
opt-in in [Permission rules](permission-rules.md#prompt-free-confined-shell-for-a-local-model).

Native file tools have a narrower boundary: they accept workspace paths, check
realpath containment when dereferencing them, refuse symlink escapes, and do
not expose arbitrary host-file reads.

## Writable and protected paths

`workspace-write` makes these roots writable:

- every workspace root;
- shared scratch space: `/tmp`, and whatever `$TMPDIR`, `$TEMP` and `$TMP` name;
- toolchain state a build must write — dune's cache directory (whatever
  `$DUNE_CACHE_ROOT` names, else `dune` under `$XDG_CACHE_HOME` or
  `~/.cache`, resolved the way dune resolves it), and on macOS the per-user
  Darwin cache bucket Apple's developer-tool shims use;
- absolute or `~`-relative paths in `sandbox.writable_roots`.

Mentat does not rewrite the child's environment. `$HOME`, the temp-dir family
and `$DUNE_CACHE_ROOT` are the ones you launched with, so a tool resolves the
same directories the policy grants — the two cannot disagree.

Existing paths are realpath-canonicalized before the policy is generated, so
the described path and the backend-enforced path agree across symlinks such as
macOS `/tmp`.

The following remain read-only even when nested under a writable root:

- existing workspace `.git` and `.mentat` entries;
- linked-worktree Git metadata outside the workspace;
- the user config, credential, and trust-store directories;
- the project config directory;
- the session store root.

Native mutation tools share the `.git` and `.mentat` protection. They also
validate workspace containment independently of the command sandbox.

On macOS, the per-session launchd endpoints under `/private/tmp` — where the
ssh-agent socket `$SSH_AUTH_SOCK` names lives — are denied outright: reads,
writes, and socket connects, in every posture, network-enabled included. The
directory sits inside the shared scratch grant, so without the denial the
agent that signs for every host you can reach would be one glob and one
connect away; stripping the variable from the environment alone is friction,
not a boundary. The same directory hosts other per-session launchd endpoints
— an XQuartz display socket among them — so a confined command cannot reach
an X11 display either; that is the accepted cost of closing the agent.

Machine-global toolchain state — the OPAM root and the dune and uv config
directories — is admitted read-only under the project read scope so tools
resolve their real locations.

Git's global configuration — `~/.gitconfig` and the `git` directory under
`$XDG_CONFIG_HOME`, or the file `$GIT_CONFIG_GLOBAL` names instead — is
admitted read-only for the same reason, with a sharper edge behind it: git
treats a config file it cannot read as fatal rather than absent, so without
the admit every git command in a confined shell fails outright, and so does
anything that runs git underneath, dune's package revision store included.
Credential state — `~/.git-credentials`, credential-helper stores — is not
part of the admit and stays unreadable.

Dune's cache directory is the exception, and it is writable, because a build
with git-pinned sources takes a lock under it unconditionally and cannot
proceed without one. Three directories inside it stay read-only, and that split
is the whole point — each of them is something a later *unsandboxed* build
consumes without checking.

- `db`, the shared cache. Dune restores a hit by hardlinking an entry into
  `_build` without re-digesting it, so writing here reaches your next
  unsandboxed build in an unrelated project.
- `toolchains`, the compilers dune downloads. This is not a store of data but an
  installation: dune runs `ocamlc` out of it, ahead of `$PATH`, on every startup,
  and prepends its `bin` for package actions. Nothing verifies it — reuse turns
  on the directory existing, and the digest in its name covers the lockfile, not
  the installed bytes. One install serves every project on the machine, so a
  replaced binary compiles all of them.
- `git-repo`, dune's revision store. A bare git repository is a set of things
  git runs for you: a hook here fires on dune's own `update-ref`, and git config
  can name a command to execute or point the opam repository at a local path.

The lock lives outside all three, so pinned-source builds proceed. Reads stay
granted everywhere — dune has to read a compiler to run it.

## Widening a single command

When a command is refused, the narrow move is to name the directory it needed:

```
shell(command="dune build", grant_write=["/home/you/.cache/dune"])
```

`grant_write` adds those directories to the policy **for that one command**.
Everything else still applies — the read scope, the network policy, and every
denial — and nothing is remembered: the next command runs under the unmodified
posture. Each path must be an existing directory, so if a failure names a file,
grant the directory containing it. A path Mentat denies outright cannot be
granted.

`escalate=true` remains for access that is genuinely broader than a set of
directories; it drops the enforcing profile entirely for that command. Both
need explicit approval, both are unavailable in `read-only` runs, and they
cannot be combined. Prefer the grant: it costs one directory rather than the
whole posture.

## Network policy

`sandbox.network=restricted` is the default for `read-only` and
`workspace-write`. Linux Bubblewrap creates a separate network namespace;
macOS Seatbelt omits network permission from its profile. Set
`sandbox.network=enabled` or `MENTAT_SANDBOX_NETWORK=enabled` to permit network
for confined shell commands.

This setting does not authorize a command under the permission policy and does
not control provider calls or web tools. Web fetching has separate enablement,
private-network checks, URL policy, and permission facts.

## Exact child environments

Every spawned route — confined, direct, externally sandboxed, and approved
escalation — receives one exact environment constructed when the run resolves its
sandbox. Tools cannot add per-call overlays and no route inherits the ambient
process environment.

The ambient environment the construction reads is the one you launched from —
including under `--attach`: the client ships its environment snapshot with
every handshake, and the daemon resolves a freshly booted workspace instance
against the snapshot of the client that boots it, not against whichever shell
happened to spawn the daemon. A live instance keeps the environment it booted
with for its life; two clients sharing one workspace share the first binder's
resolution, because the instance is one engine and one sealed sandbox.

The child environment contains:

- `PATH`, validated as absolute non-empty entries;
- private run-owned `HOME`, `TMPDIR`, `TMP`, and `TEMP`;
- deterministic non-interactive pager, terminal, and color settings;
- valid locale and OCaml toolchain path variables from a fixed allowlist;
- a curated build-tool set, verbatim: the C toolchain (`CC`, `CXX`, the
  `*FLAGS` families), `PKG_CONFIG`/`PKG_CONFIG_PATH`/`PKG_CONFIG_LIBDIR`,
  the proxy variables in both spellings (`HTTPS_PROXY`, `https_proxy`, …),
  TLS trust (`SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`), and git
  identity (`GIT_AUTHOR_*`, `GIT_COMMITTER_*`, `EMAIL`) — so a `conf-*`
  probe, a fetch behind a proxy, or a C stub compiles exactly as it would
  from your shell;
- the dune and OCaml configuration families, verbatim: every `DUNE_*`,
  `OCAML*` and `CAML*` variable you launched with — `DUNE_CACHE`,
  `DUNE_PROFILE`, `DUNE_SANDBOX`, `DUNE_CONFIG__*`, `OCAMLPARAM`, and the
  rest. Dune folds its configuration into the digest of every rule, so a
  build that saw a different configuration from your shell would re-execute
  your whole build and have its own re-executed back on your next one. The
  handles dune assigns to the actions it spawns (`DUNE_ACTION_TRACE_DIR`,
  `DUNE_SOURCEROOT`, `DUNE_DIR_LOCATIONS`) describe a running dune rather
  than configure one and are not inherited.

Optional inherited values that are malformed are omitted. Values are never
included in sandbox diagnostics. After repository activation, an existing
canonical workspace-local `_opam/bin` leads `PATH`; a restricted repository
cannot contribute executable roots.

### Inheriting more, or less

`sandbox.env_inherit=all` (or `MENTAT_SANDBOX_ENV_INHERIT=all`) additionally
inherits every remaining ambient variable — the widest posture, offered as an
explicit choice rather than a default. A built-in floor survives it:
names matching `*KEY*`, `*SECRET*`, `*TOKEN*`, `*PASSWORD*`, `*PASSWD*`,
`*CREDENTIAL*`, the agent handles (`SSH_AUTH_SOCK`, `SSH_AGENT_PID`,
`GPG_AGENT_INFO`, `DBUS_SESSION_BUS_ADDRESS`), `MENTAT_*`, and dune's
running-instance handles never reach a child, and no setting subtracts from
the floor. A pattern floor is best-effort — a credential inside
`DATABASE_URL` does not match it — so weigh what your shell exports before
choosing `all`.

`sandbox.env_exclude` removes case-insensitive `*`-glob matches from the
inheritable sets on top of the floor; `sandbox.env_include_only`, when
non-empty, is the hard mode: only matching inheritable names reach the child.
Neither governs the structural core — `PATH`, `HOME`, the temp-dir family and
the base directories the policy derives grants from — which the child and the
policy must always agree on.

The `shell` tool runs its command with `-c`, not as a login shell, for the
same reason: a login shell re-sources your profile on top of the constructed
environment — on macOS `path_helper` moves the system directories to the
front of `PATH`, and a profile that evaluates `opam env` prepends a switch —
so it would resolve `dune`, `cc`, `make` or `git` to different binaries than
the shell you build from. Set `MENTAT_SHELL` to choose the shell; its
`-c` invocation sees exactly the environment above.

## Enforcement requirements and backends

`sandbox.require` controls the run-start gate:

| Value | Gate behavior |
| --- | --- |
| `enforced` | Default. Confined modes require a working Mentat backend; an external declaration is not sufficient. |
| `enforced-or-external` | Accepts either a working Mentat backend or `external-sandbox`. |
| `off` | Does not fail the run at startup. A confined mode with no backend still refuses each shell command rather than running it unconfined. |

`--require-sandbox` forces `enforced-or-external` for one invocation.

Mentat selects `/usr/bin/bwrap` on Linux and `/usr/bin/sandbox-exec` on macOS.
The Linux path is fixed: a `bwrap` found elsewhere on `PATH` is not selected.
Bubblewrap is unavailable on WSL1 and is probed with a minimal isolated process
before use. Other platforms have no built-in enforcing backend. A restricted
run fails closed when its applicable requirement is not met. See
[Installation](installation.md) for the host prerequisite matrix.

## Per-command widening, reviewed

In a `workspace-write` sandbox the model can ask for one of two widenings on a
single shell call, and each adds its own reviewable access beside the ordinary
command access. Reaching execution means both were allowed by policy or
reviewer.

`grant_write` adds a `shell.grant` access whose subject is the granted
directories. An approved grant:

- keeps the enforcing profile and adds those directories for that command;
- leaves every other clause standing, denials included;
- records ordinary `enforced` evidence, naming the profile that actually ran;
- is not remembered — the next command runs under the unmodified posture.

`escalate:true` adds a `shell.escalate` access whose subject is the exact
command text. An approved escalation:

- runs that one command without filesystem or network confinement;
- retains the policy's exact child environment;
- records `not_requested` sandbox evidence;
- does not broaden to another command, even after an exact-conversation answer.

Read-only mode refuses both without opening a permission review: the posture
promises no mutation, and a write grant is a mutation. In
`danger-full-access` and `external-sandbox` both are ignored because the
requested lack of Mentat confinement is already the current posture.
