(lang dune 3.22)

(name mentat)

(generate_opam_files)

; Keep dependency declarations honest: each stanza must name the libraries it
; uses instead of compiling through transitive dependencies.
(implicit_transitive_deps false)

(source
 (github invariant-hq/mentat))

(homepage "https://github.com/invariant-hq/mentat")

(documentation "https://github.com/invariant-hq/mentat#readme")

(bug_reports "https://github.com/invariant-hq/mentat/issues")

(authors "Thibaut Mattio <thibaut.mattio@gmail.com>")

(maintainers "Thibaut Mattio <thibaut.mattio@gmail.com>")

(maintenance_intent "(latest)")

(license ISC)

; These packages are developed together in the Mosaic repository. Pin them as a
; group so the TUI stack resolves from one compatible source revision.
(pin
 (url "git+https://github.com/invariant-hq/mosaic")
 (package
  (name tree-sitter)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic")
 (package
  (name matrix)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic")
 (package
  (name matrix-eio)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic")
 (package
  (name toffee)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic")
 (package
  (name mosaic)))

(pin
 (url "git+https://github.com/invariant-hq/thumper.git")
 (package
  (name thumper)))

(pin
 (url "git+https://github.com/invariant-hq/litany.git")
 (package
  (name litany)))

; Windtrap 0.2.0 pre-release dogfood: pin the upstream repository until
; the release lands in the package repository.
(pin
 (url "git+ssh://git@github.com/invariant-hq/windtrap.git")
 (package
  (name windtrap)))

(pin
 (url "git+ssh://git@github.com/invariant-hq/windtrap.git")
 (package
  (name ppx_windtrap)))

(package
 (name mentat)
 (synopsis "The OCaml coding agent")
 (description
  "Mentat is a coding agent specialized for OCaml development. It uses OCaml's type system, build tools, package ecosystem, and editor diagnostics as first-class context so agents can make changes that are faster to produce, easier to review, and less likely to break than generic coding-agent output.\n\nMentat is built for safer, more productive agentic development in real OCaml codebases.")
 (depends
  (ocaml
   (>= 5.5.0))
  ; JSON/codecs and byte streams.
  (jsont
   (>= 0.2.0))
  (bytesrw
   (>= 0.3.0))
  ; Media and bundle payloads use Base64; session and web views render Markdown
  ; through Cmarkit.
  base64
  cmarkit
  ; Command-line surface and shared runtime plumbing.
  (cmdliner
   (>= 2.0.0))
  ; Diagnostics logging: libraries declare sources, the binary owns the
  ; reporter and level policy.
  (logs
   (>= 0.10.0))
  mtime
  ; OCaml-aware tools talk to Dune through RPC and csexp.
  csexp
  dune-build-info
  dune-rpc
  ; Effects-based I/O. 1.4 supplies the directory read that carries each entry's
  ; kind, open_subtree, unlink's missing_ok, and the resolver and spawn failures
  ; the transports classify. The backends pin eio exactly, so this bound carries
  ; eio_main with it.
  (eio
   (>= 1.4))
  eio_main
  xdg
  ; HTTP/TLS client stack used by hosted LLM providers and web tools.
  ca-certs
  cohttp
  cohttp-eio
  cstruct
  domain-name
  mirage-crypto-rng
  tls
  tls-eio
  uri
  ; Web transport validates IP addresses; shell tools compile regular
  ; expressions.
  ipaddr
  re
  ; Workspace I/O converts Eio file offsets and sizes through Optint.
  optint
  ; Skills use markdown documents with YAML frontmatter.
  yaml
  ; Terminal UI stack from the Mosaic repository pins above.
  mosaic
  matrix
  matrix-eio
  ; TUI syntax highlighting uses the OCaml and JSON grammar libraries.
  tree-sitter
  ; The black-box fake Dune RPC server builds protocol replies with Pp.
  (pp :with-test)
  ; Expect-style tests.
  (windtrap
   (and
    :with-test
    (>= 0.2.0)))
  (ppx_windtrap
   (and
    :with-test
    (>= 0.2.0)))
  ; House benchmarking harness for the bench/ suites.
  (thumper :with-test)
  ; Linting
  (litany :with-test))
 (tags
  (ai cli coding-agent developer-tools ocaml org:invariant-hq)))
