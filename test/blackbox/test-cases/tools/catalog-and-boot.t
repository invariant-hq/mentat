The executable composition exposes every green tool exactly once, while Merlin
program resolution observes the sealed workspace once and never starts Dune.

  $ use_trusted_workspace
  $ unset MENTAT_DUNE MENTAT_OCAMLMERLIN OPAM_SWITCH_PREFIX
  $ export MENTAT_DUNE_WATCH=observe
  $ mkdir -p "$XDG_CONFIG_HOME/mentat"
  $ printf '%s\n' 'let answer = 42' > sample.ml
  $ : > dune-project
  $ write_config () {
  >   editor=${2:-auto}; tooling=${3:-auto}; web=${4:-false}
  >   printf '{"permission":{"rules":{"version":1,"items":[{"action":"allow","matcher":{"type":"any"}}]}},"ocaml":{"merlin_program":%s},"tools":{"editor":"%s"},"workspace":{"tooling":"%s"},"web":{"enabled":%s}}\n' "$1" "$editor" "$tooling" "$web" > "$XDG_CONFIG_HOME/mentat/config.json"
  > }
  $ capture_catalog () {
  >   name=$1; run_root=${2:-$PWD}
  >   cat > "$name.jsonl" <<JSONL
  > {"expect":{"body_contains":["$name catalog"]},"response":{"id":"$name","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"captured"}]}]}}
  > JSONL
  >   start_fake_openai "$name.jsonl" "capture-$name" "port-$name"
  >   mentat run start --id "$name" "$name catalog" --cwd "$run_root" >/dev/null 2>/dev/null
  >   wait_fake_server
  > }

The provider request is the product-level catalog boundary. With an apply-patch
capable model and a Dune marker, auto selects only apply_patch, includes all ten
OCaml tools, and keeps [propose_plan] reserved for Plan mode.

  $ write_config '["ocamlmerlin"]'
  $ cat > catalog.jsonl <<'JSONL'
  > {"expect":{"body_contains":["catalog prompt","\"name\":\"read_file\"","\"name\":\"ocaml_docs\""]},"response":{"id":"catalog-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"catalog captured"}]}]}}
  > JSONL
  $ start_fake_openai catalog.jsonl capture-catalog port-catalog
  $ mentat run start --id tool-catalog "catalog prompt" --cwd "$PWD" 2>/dev/null
  catalog captured
  $ wait_fake_server
  $ mentat_cram json '.tools[].name' capture-catalog/request-1.json | sort
  apply_patch
  ask_user
  follow_up
  glob
  ocaml_ast_edit
  ocaml_docs
  ocaml_eval
  ocaml_find_definitions
  ocaml_find_references
  ocaml_rename
  ocaml_replace_expressions
  ocaml_search_expressions
  ocaml_type_at
  read_file
  search_text
  send_message
  shell
  shell_kill
  shell_output
  skill
  spawn
  todo_write
  wait
  $ mentat_cram json '.tools[].name' capture-catalog/request-1.json > catalog-names
  $ grep -qx web_fetch catalog-names && echo present || echo absent
  absent

Both explicit editor overrides win over model capability metadata, and each
still mints exactly one editor family.

  $ write_config '["ocamlmerlin"]' string-replace on
  $ capture_catalog editor-string
  $ mentat_cram json '.tools[].name' capture-editor-string/request-1.json | grep -E '^(apply_patch|edit_file|write_file)$' | sort
  edit_file
  write_file
  $ write_config '["ocamlmerlin"]' apply-patch on
  $ capture_catalog editor-patch
  $ mentat_cram json '.tools[].name' capture-editor-patch/request-1.json | grep -E '^(apply_patch|edit_file|write_file)$' | sort
  apply_patch

Auto falls back to string replacement when the resolved model lacks the
apply-patch capability. The fake response is intentionally not an Anthropic
message; only the captured provider request is under test.

  $ write_config '["ocamlmerlin"]' auto on
  $ cat > editor-auto-fallback.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"model\":\"claude-sonnet-5\""]},"response":{"id":"not-anthropic","status":"completed","model":"claude-sonnet-5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ignored"}]}]}}
  > JSONL
  $ start_fake_server editor-auto-fallback.jsonl capture-editor-auto-fallback port-editor-auto-fallback
  $ export ANTHROPIC_API_KEY=test-key
  $ export MENTAT_MODEL=anthropic/claude-sonnet-5
  $ export MENTAT_ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat port-editor-auto-fallback)/v1"
  $ mentat run start --id editor-auto-fallback "fallback catalog" --cwd "$PWD" >/dev/null 2>/dev/null || true
  $ wait_fake_server
  $ mentat_cram json '.tools[].name' capture-editor-auto-fallback/request-1.json | grep -E '^(apply_patch|edit_file|write_file)$' | sort
  edit_file
  write_file
  $ unset ANTHROPIC_API_KEY MENTAT_ANTHROPIC_BASE_URL

Workspace tooling gates the seven project-scoped OCaml tools. Explicit off wins
even with a marker; explicit on wins without one; and each launched process in
the auto cases observes either Dune marker as it starts.

  $ write_config '["ocamlmerlin"]' auto off
  $ capture_catalog tooling-off
  $ mentat_cram json '.tools[].name' capture-tooling-off/request-1.json | grep '^ocaml_' | sort
  ocaml_ast_edit
  ocaml_replace_expressions
  ocaml_search_expressions
  $ rm dune-project
  $ write_config '["ocamlmerlin"]' auto on
  $ capture_catalog tooling-on
  $ mentat_cram json '.tools[].name' capture-tooling-on/request-1.json | grep '^ocaml_' | sort
  ocaml_ast_edit
  ocaml_docs
  ocaml_eval
  ocaml_find_definitions
  ocaml_find_references
  ocaml_rename
  ocaml_replace_expressions
  ocaml_search_expressions
  ocaml_type_at
  $ write_config '["ocamlmerlin"]' auto auto
  $ capture_catalog tooling-auto-empty
  $ mentat_cram json '.tools[].name' capture-tooling-auto-empty/request-1.json | grep '^ocaml_' | sort
  ocaml_ast_edit
  ocaml_replace_expressions
  ocaml_search_expressions
  $ : > dune-workspace
  $ capture_catalog tooling-auto-marker
  $ mentat_cram json '.tools[].name' capture-tooling-auto-marker/request-1.json | grep '^ocaml_' | wc -l | tr -d ' '
  9

These separate-process captures prove marker kind and containment: a directory
does not engage project tooling, an admitted in-root symlink to a regular marker
does, and an escaping symlink fails closed. They do not exercise two fresh
turns on one cached client.

  $ rm dune-workspace
  $ mkdir dune-project
  $ capture_catalog tooling-auto-directory
  $ mentat_cram json '.tools[].name' capture-tooling-auto-directory/request-1.json | grep '^ocaml_' | wc -l | tr -d ' '
  3
  $ rmdir dune-project
  $ mkdir marker-target
  $ : > marker-target/dune-project
  $ ln -s marker-target/dune-project dune-project
  $ capture_catalog tooling-auto-in-root-symlink
  $ mentat_cram json '.tools[].name' capture-tooling-auto-in-root-symlink/request-1.json | grep '^ocaml_' | wc -l | tr -d ' '
  9
  $ rm dune-project
  $ mkdir ../outside-marker
  $ : > ../outside-marker/dune-project
  $ ln -s ../outside-marker/dune-project dune-project
  $ capture_catalog tooling-auto-escaping-symlink
  $ mentat_cram json '.tools[].name' capture-tooling-auto-escaping-symlink/request-1.json | grep '^ocaml_' | wc -l | tr -d ' '
  3
  $ rm dune-project

Read-only Build keeps the Build interaction verbs, shell, native reads/search,
and applicable non-editing OCaml tools. It omits exactly the native editor
families: `write_file`, `edit_file`, `apply_patch`, `ocaml_ast_edit`,
`ocaml_replace_expressions`, and `ocaml_rename`.

  $ export MENTAT_SANDBOX_MODE=read-only MENTAT_SANDBOX_REQUIRE=off
  $ write_config '["ocamlmerlin"]' apply-patch off
  $ capture_catalog read-only-build-off
  $ mentat_cram json '.tools[].name' capture-read-only-build-off/request-1.json | sort
  ask_user
  follow_up
  glob
  ocaml_search_expressions
  read_file
  search_text
  send_message
  shell
  shell_kill
  shell_output
  skill
  spawn
  todo_write
  wait
  $ write_config '["ocamlmerlin"]' string-replace on
  $ capture_catalog read-only-build-on
  $ mentat_cram json '.tools[].name' capture-read-only-build-on/request-1.json | sort
  ask_user
  follow_up
  glob
  ocaml_docs
  ocaml_eval
  ocaml_find_definitions
  ocaml_find_references
  ocaml_search_expressions
  ocaml_type_at
  read_file
  search_text
  send_message
  shell
  shell_kill
  shell_output
  skill
  spawn
  todo_write
  wait
  $ write_config '["ocamlmerlin"]' string-replace on true
  $ capture_catalog read-only-build-web
  $ mentat_cram json '.tools[].name' capture-read-only-build-web/request-1.json | grep -E '^(apply_patch|edit_file|write_file|ocaml_ast_edit|ocaml_replace_expressions|ocaml_rename|web_fetch)$' | sort
  web_fetch
  $ unset MENTAT_SANDBOX_REQUIRE
  $ export MENTAT_SANDBOX_MODE=danger-full-access

The finite Build family has four full catalogs (editor family by project
tooling) and two read-only-workspace catalogs (project tooling only). Their
complete declaration lists are pairwise distinct; the two read-only members do
not preserve a meaningless editor dimension.

  $ write_config '["ocamlmerlin"]' string-replace off
  $ capture_catalog full-string-off
  $ mkdir build-catalog-family
  $ mentat_cram json '.tools[].name' capture-tooling-off/request-1.json | sort > build-catalog-family/full-patch-off
  $ mentat_cram json '.tools[].name' capture-editor-patch/request-1.json | sort > build-catalog-family/full-patch-on
  $ mentat_cram json '.tools[].name' capture-full-string-off/request-1.json | sort > build-catalog-family/full-string-off
  $ mentat_cram json '.tools[].name' capture-editor-string/request-1.json | sort > build-catalog-family/full-string-on
  $ mentat_cram json '.tools[].name' capture-read-only-build-off/request-1.json | sort > build-catalog-family/read-only-off
  $ mentat_cram json '.tools[].name' capture-read-only-build-on/request-1.json | sort > build-catalog-family/read-only-on
  $ set -- build-catalog-family/*; comparisons=0; duplicates=0; while [ $# -gt 0 ]; do left=$1; shift; for right in "$@"; do comparisons=$((comparisons + 1)); if cmp -s "$left" "$right"; then duplicates=$((duplicates + 1)); fi; done; done; echo "$comparisons comparisons, $duplicates duplicates"
  15 comparisons, 0 duplicates

Trust is an independent ceiling: [workspace.tooling=on] cannot expose project
tools in an untrusted workspace, even when that workspace has a Dune marker.

  $ mkdir -p untrusted/.git
  $ : > untrusted/dune-project
  $ write_config '["ocamlmerlin"]' auto on
  $ capture_catalog tooling-untrusted "$PWD/untrusted"
  $ mentat_cram json '.tools[].name' capture-tooling-untrusted/request-1.json | grep '^ocaml_' | sort
  ocaml_ast_edit
  ocaml_replace_expressions
  ocaml_search_expressions

Delegated sessions receive the same project-tool gate over their fixed
read-only vocabulary: four executables while tooling is off and the exact seven
when it is engaged. Their collaboration verbs are unchanged. The child is a
read-only specialist: a `general` child is a full-capability delegate carrying
the parent catalog, which would prove nothing about the gate.

  $ capture_delegated () {
  >   name=$1
  >   cat > "$name.jsonl" <<JSONL
  > {"expect":{"body_contains":["$name parent"]},"response":{"id":"$name-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"spawn-item","call_id":"spawn-call","name":"spawn","arguments":"{\"task\":\"inspect delegated tools\",\"role\":\"explore\"}"}]}}
  > {"expect":{"body_contains":["\"model\":\"gpt-5.6-sol\""]},"response":{"id":"$name-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > {"expect":{"body_contains":["\"model\":\"gpt-5.6-sol\""]},"response":{"id":"$name-3","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}
  > JSONL
  >   start_fake_openai "$name.jsonl" "capture-$name" "port-$name"
  >   mentat run start --id "$name" "$name parent" --cwd "$PWD" >/dev/null 2>/dev/null
  >   wait_fake_server
  > }
  $ write_config '["ocamlmerlin"]' auto off
  $ capture_delegated delegated-off
  $ delegated_request=$(grep -L '"name":"ask_user"' capture-delegated-off/request-*.json)
  $ mentat_cram json '.tools[].name' "$delegated_request" | grep -E '^(glob|read_file|search_text|ocaml_)' | sort
  glob
  ocaml_search_expressions
  read_file
  search_text
  $ write_config '["ocamlmerlin"]' auto on
  $ capture_delegated delegated-on
  $ delegated_request=$(grep -L '"name":"ask_user"' capture-delegated-on/request-*.json)
  $ mentat_cram json '.tools[].name' "$delegated_request" | grep -E '^(glob|read_file|search_text|ocaml_)' | sort
  glob
  ocaml_find_definitions
  ocaml_find_references
  ocaml_search_expressions
  ocaml_type_at
  read_file
  search_text

  $ write_config '["ocamlmerlin"]' auto on

A bare default resolves from the captured toolchain PATH and is pinned before
the provider asks for a Merlin-backed tool.

  $ mkdir -p fake-bin
  $ cat > fake-bin/ocamlmerlin <<'SH'
  > #!/bin/sh
  > printf '%s\n' "$*" >> merlin-default.log
  > printf '%s' '{"class":"return","value":[{"start":{"line":1,"col":4},"end":{"line":1,"col":10},"type":"int","tail":"no"}]}'
  > SH
  $ chmod +x fake-bin/ocamlmerlin
  $ old_path=$PATH; export PATH="$PWD/fake-bin:$PATH"
  $ cat > default.jsonl <<'JSONL'
  > {"expect":{"body_contains":["default prefix"]},"response":{"id":"default-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"default-item","call_id":"default-call","name":"ocaml_type_at","arguments":"{\"path\":\"sample.ml\",\"line\":1,\"column\":4}"}]}}
  > {"expect":{"body_contains":["function_call_output","default-call","OCaml type at"]},"response":{"id":"default-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"default resolved"}]}]}}
  > JSONL
  $ start_fake_openai default.jsonl capture-default port-default
  $ mentat run start --id tool-default "default prefix" --cwd "$PWD" 2>/dev/null
  default resolved
  $ wait_fake_server
  $ wc -l < merlin-default.log | tr -d ' '
  1
  $ head -n 1 merlin-default.log | cut -d ' ' -f 1-2
  single type-enclosing

Only the exact five-token Dune form is special. A wrapper containing the same
tokens remains byte-for-byte at the head of the Merlin invocation.

  $ cat > fake-bin/wrapper <<'SH'
  > #!/bin/sh
  > printf '%s\n' "$*" >> wrapper.log
  > printf '%s' '{"class":"return","value":[{"start":{"line":1,"col":4},"end":{"line":1,"col":10},"type":"int","tail":"no"}]}'
  > SH
  $ chmod +x fake-bin/wrapper
  $ write_config '["wrapper","dune","tools","exec","near-match","--"]' auto on
  $ cat > wrapper.jsonl <<'JSONL'
  > {"expect":{"body_contains":["wrapper prefix"]},"response":{"id":"wrapper-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"wrapper-item","call_id":"wrapper-call","name":"ocaml_type_at","arguments":"{\"path\":\"sample.ml\",\"line\":1,\"column\":4}"}]}}
  > {"expect":{"body_contains":["function_call_output","wrapper-call","OCaml type at"]},"response":{"id":"wrapper-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"wrapper preserved"}]}]}}
  > JSONL
  $ start_fake_openai wrapper.jsonl capture-wrapper port-wrapper
  $ mentat run start --id tool-wrapper "wrapper prefix" --cwd "$PWD" 2>/dev/null
  wrapper preserved
  $ wait_fake_server
  $ head -n 1 wrapper.log | cut -d ' ' -f 1-6
  dune tools exec near-match -- single

An already-built dev tool is selected by filesystem observation; Dune is not
started.

  $ mkdir -p _build/_private/default/.dev-tool/existing/target/bin
  $ cat > _build/_private/default/.dev-tool/existing/target/bin/existing-merlin <<'SH'
  > #!/bin/sh
  > printf '%s\n' "$*" >> existing-merlin.log
  > printf '%s' '{"class":"return","value":[{"start":{"line":1,"col":4},"end":{"line":1,"col":10},"type":"int","tail":"no"}]}'
  > SH
  $ chmod +x _build/_private/default/.dev-tool/existing/target/bin/existing-merlin
  $ cat > fake-bin/dune <<'SH'
  > #!/bin/sh
  > printf '%s\n' "$*" >> existing-dune.log
  > SH
  $ chmod +x fake-bin/dune
  $ write_config '["dune","tools","exec","existing-merlin","--"]' auto on
  $ cat > existing.jsonl <<'JSONL'
  > {"expect":{"body_contains":["existing dev tool"]},"response":{"id":"existing-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"existing-item","call_id":"existing-call","name":"ocaml_type_at","arguments":"{\"path\":\"sample.ml\",\"line\":1,\"column\":4}"}]}}
  > {"expect":{"body_contains":["function_call_output","existing-call","OCaml type at"]},"response":{"id":"existing-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"existing selected"}]}]}}
  > JSONL
  $ start_fake_openai existing.jsonl capture-existing port-existing
  $ mentat run start --id tool-existing "existing dev tool" --cwd "$PWD" 2>/dev/null
  existing selected
  $ wait_fake_server
  $ test ! -e existing-dune.log; echo $?
  0
  $ wc -l < existing-merlin.log | tr -d ' '
  1

A non-regular entry at the expected dev-tool path is not treated as an
executable. Lookup ignores the directory, never starts Dune, and composition
uses the captured plain Merlin fallback.

  $ mkdir -p _build/_private/default/.dev-tool/directory/target/bin/directory-merlin
  $ write_config '["dune","tools","exec","directory-merlin","--"]' auto on
  $ cat > directory.jsonl <<'JSONL'
  > {"expect":{"body_contains":["directory dev entry"]},"response":{"id":"directory-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"directory-item","call_id":"directory-call","name":"ocaml_type_at","arguments":"{\"path\":\"sample.ml\",\"line\":1,\"column\":4}"}]}}
  > {"expect":{"body_contains":["function_call_output","directory-call","OCaml type at"]},"response":{"id":"directory-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"directory ignored"}]}]}}
  > JSONL
  $ start_fake_openai directory.jsonl capture-directory port-directory
  $ mentat run start --id tool-directory "directory dev entry" --cwd "$PWD" 2>/dev/null
  directory ignored
  $ wait_fake_server
  $ test -d _build/_private/default/.dev-tool/directory/target/bin/directory-merlin; echo $?
  0
  $ test ! -e existing-dune.log; echo $?
  0
  $ wc -l < merlin-default.log | tr -d ' '
  2

A cold exact Dune prefix stays observational. Even a Dune executable that would
materialize the requested tool is never started; composition falls back to the
plain captured Merlin spelling and keeps the tool available.

  $ cat > fake-bin/dune <<'SH'
  > #!/bin/sh
  > printf '%s\n' "$*" >> cold-dune.log
  > mkdir -p _build/_private/default/.dev-tool/cold/target/bin
  > cat > _build/_private/default/.dev-tool/cold/target/bin/cold-merlin <<'TOOL'
  > #!/bin/sh
  > printf '%s\n' "$*" >> cold-merlin.log
  > printf '%s' '{"class":"return","value":[{"start":{"line":1,"col":4},"end":{"line":1,"col":10},"type":"int","tail":"no"}]}'
  > TOOL
  > chmod +x _build/_private/default/.dev-tool/cold/target/bin/cold-merlin
  > SH
  $ chmod +x fake-bin/dune
  $ write_config '["dune","tools","exec","cold-merlin","--"]' auto on
  $ cat > cold.jsonl <<'JSONL'
  > {"expect":{"body_contains":["cold lookup"]},"response":{"id":"cold-1","status":"completed","model":"gpt-5.6-sol","output":[{"type":"function_call","id":"cold-item","call_id":"cold-call","name":"ocaml_type_at","arguments":"{\"path\":\"sample.ml\",\"line\":1,\"column\":4}"}]}}
  > {"expect":{"body_contains":["function_call_output","cold-call","OCaml type at"]},"response":{"id":"cold-2","status":"completed","model":"gpt-5.6-sol","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"cold used fallback"}]}]}}
  > JSONL
  $ start_fake_openai cold.jsonl capture-cold port-cold
  $ mentat run start --id tool-cold "cold lookup" --cwd "$PWD" 2>/dev/null
  cold used fallback
  $ wait_fake_server
  $ test ! -e cold-dune.log; echo $?
  0
  $ test ! -e _build/_private/default/.dev-tool/cold/target/bin/cold-merlin; echo $?
  0
  $ wc -l < merlin-default.log | tr -d ' '
  3
  $ export PATH="$old_path"
