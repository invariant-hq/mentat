# Getting started

This walks you through one change made by the agent, from an empty
configuration to reviewing and undoing the result. It takes about ten minutes
and ends with your files exactly as they started, so nothing here is
destructive.

You will use a small throwaway project rather than your own code, so that the
output on your screen matches the output printed here. The last section moves
you onto a real codebase.

## Before you start

- Mentat installed and on your `PATH`. See [Installation](installation.md).
- Dune 3.20 or later.
- An account with a model provider. This tutorial was recorded against
  Anthropic; OpenAI and Google work the same way.

Check the binary is reachable:

```sh
mentat --version
```

## 1. Create a project to practise on

Make a small library with one module and no interface file:

```sh
mkdir -p ~/mentat-tutorial/lib && cd ~/mentat-tutorial
```

Create `dune-project`:

```
(lang dune 3.20)

(package
 (name greeter)
 (depends
  (ocaml
   (>= 5.1))))
```

Create `lib/dune`:

```
(library
 (name greeter)
 (public_name greeter))
```

Create `lib/user.ml`:

```ocaml
type t = { name : string; email : string }

let make ~name ~email = { name; email }
let name t = t.name
let email t = t.email

let display t =
  if String.length t.name = 0 then t.email else t.name ^ " <" ^ t.email ^ ">"

let is_valid t = String.contains t.email '@' && String.length t.name > 0
```

Lock the dependencies and build:

```sh
dune pkg lock
dune build
```

The first lock provisions an OCaml compiler and takes a few minutes. When
`dune build` prints nothing, the project is green and you are ready.

## 2. Authenticate

Log in to a provider:

```sh
mentat auth login anthropic
```

Confirm it worked:

```sh
mentat auth status
```

```
PROVIDER     PHASE      CONNECTED
openai       unchecked  no
anthropic    unchecked  yes
google       unchecked  no
local        missing    no
ollama       missing    no
opencode-go  missing    no
```

`CONNECTED` means a credential is stored. `PHASE` stays `unchecked` until the
first request actually uses the provider.

Before you send anything to a hosted model, read
[Data leaving your machine](security.md#data-leaving-your-machine). Model
requests can carry your prompts, source files, and tool output.

## 3. Trust the workspace

Mentat does not read project-local configuration, instructions, or skills from
a directory you have not trusted. Trust this one:

```sh
mentat trust
```

```
trusted /Users/you/mentat-tutorial
```

Trust is per workspace and durable. Untrust it later with `mentat untrust`.

## 4. Ask for a change

Run a headless turn. Headless mode prints what the agent does as it does it,
which makes it the clearest way to see the loop for the first time:

```sh
mentat run "Add an .mli interface file for lib/user.ml that exposes only the type t, make, name, email, and display. Then make sure the project builds."
```

The output looks like this, abbreviated:

```
mentat: sandbox: workspace-write (read project, network restricted)
• tool read_file
• tool search_text
• tool glob
No other references to User exist outside lib/user.ml (nothing uses is_valid
elsewhere), so I can write the .mli safely.
• tool write_file
• tool shell
• tool read_file
`is_valid` is unused elsewhere and no longer exported, which trips warning 32
as an error. Since it's genuinely dead code now, I'll remove it per the
"delete unused code" convention rather than patch around the warning.
• tool edit_file
• tool shell
The build is green.

Summary of changes:
- Added `lib/user.mli` exposing `type t`, `make`, `name`, `email`, `display`.
- Removed `is_valid` from `lib/user.ml`: with the new `.mli` it wasn't
  exported and had no other callers, so it became dead code and tripped
  warning 32 as a build error.

mentat: session saved; resume with: mentat run resume 's-1784970383883-38ad'
```

Your session id and the exact wording will differ. The shape will not.

## 5. What just happened

This is the part worth slowing down for.

The agent wrote `lib/user.mli`, and that broke the build. Restricting the
module's interface made `is_valid` unreachable from outside, so the compiler
reported it as an unused value, and this project treats warnings as errors.

Nothing told the agent about that error. It ran the build, read the failure,
worked out that the value was now genuinely dead rather than accidentally
hidden, deleted it, and built again. The turn ended because the build was
green, not because the file had been written.

That is the loop Mentat is built around: a change is not done when the edit
lands, it is done when the compiler agrees. On a generic agent the same
request usually ends one step earlier, with a written file and a broken build.

The first line of the output records the sandbox the commands ran under:

```
mentat: sandbox: workspace-write (read project, network restricted)
```

The agent could write inside the workspace, read the project, and reach no
network. See [Security](security.md) for the other modes.

## 6. Review the change

Every session records what it edited. Ask what this one did:

```sh
mentat session diff --last
```

```
A lib/user.mli
--- lib/user.mli
@@ -0,0 +1,6 @@
+type t
+
+val make : name:string -> email:string -> t
+val name : t -> string
+val email : t -> string
+val display : t -> string
M lib/user.ml
--- lib/user.ml
@@ -6,5 +6,3 @@
 
 let display t =
   if String.length t.name = 0 then t.email else t.name ^ " <" ^ t.email ^ ">"
-
-let is_valid t = String.contains t.email '@' && String.length t.name > 0
changed 2 file(s) (+6 -2)
```

`A` marks an added file, `M` a modified one. This comes from the session's
mutation ledger, not from Git, so it works in a project with no repository and
it shows only what the agent changed.

## 7. Undo it

```sh
mentat session revert --last
```

```
would revert 2 file(s):
D lib/user.mli
M lib/user.ml
apply: mentat session revert --apply s-1784970383883-38ad
```

Nothing has changed yet. `session revert` previews by default and prints the
command that commits to it. Run that command:

```sh
mentat session revert --apply --last
```

```
reverted 2 file(s)
```

`lib/user.mli` is gone, `is_valid` is back, and `dune build` is green again.
The project is exactly as it was in step 1.

This is why trying Mentat on real code is cheap: every turn is recorded and
every turn is reversible.

## 8. If a run fails partway

Provider outages happen. When one does, the turn stops and the session is
kept:

```
mentat: provider failure: Service Unavailable
mentat: session saved; resume with: mentat run resume 's-1784969835802-ca6e'
```

The exit code is 1, and the printed command picks the session up where it
stopped:

```sh
mentat run resume --last "Continue."
```

No work is lost, and `--last` always refers to the most recent session in this
workspace.

## Next steps

Run it on your own project. The sequence is the same: `mentat trust` in the
project root, then ask for something small and verifiable. Because
`session diff` and `session revert` work everywhere, a first change on real
code carries no more risk than the one you just made here.

For day-to-day work you will want the terminal interface rather than headless
runs. Start it by running `mentat` with no arguments, and type `/` for the
command palette.

- [Interactive TUI](interactive.md) — composer, modes, decisions, and review.
- [Headless runs](headless.md) — flags, JSONL events, exit codes, and CI use.
- [Sessions](sessions.md) — list, resume, fork, diff, and revert.
- [Security](security.md) — what leaves your machine, permissions, sandboxing.
- [Instructions and skills](instructions-and-skills.md) — teach Mentat your
  project's conventions with `AGENTS.md`.

When you are finished with the tutorial project:

```sh
mentat untrust ~/mentat-tutorial
rm -rf ~/mentat-tutorial
```
