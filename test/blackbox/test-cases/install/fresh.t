A fresh install from a release fixture: the archive is fetched, verified
against SHA256SUMS, staged, exec-checked, and both binaries published into
--dir; a second run against the same prefix short-circuits on the installed
pair. The release source is a local file:// tree reached through the
MENTAT_INSTALL_BASE_URL test seam, so only the override path is exercised
here, and --version is always pinned: "latest" resolution is a GitHub
redirect with no local equivalent.

Drop the GitHub Actions PATH seam so a CI host cannot leak into the run
(rc-edit.t pins its behavior). The target triple in the output is the
host's; normalize it.

  $ unset GITHUB_PATH
  $ norm() { sed 's/([a-z]*-[a-z0-9]*)/(TARGET)/'; }

--help is the one flow driven without the seam: it prints before any
platform or network work.

  $ sh install.sh --help
  Install mentat, the OCaml coding agent.
  
    curl -fsSL https://raw.githubusercontent.com/invariant-hq/mentat/main/scripts/install.sh | sh
  
  Options (flags or environment variables):
    -v, --version X.Y.Z    install a specific release  (MENTAT_VERSION)
    -d, --dir DIR          install directory           (MENTAT_INSTALL_DIR,
                           default ~/.local/bin)
        --no-modify-path   never edit shell rc files

The release fixture: stub binaries whose --version prints the release tag
(the staged exec check and the idempotence probe both read it), archived
under every platform name the installer can derive so one fixture serves any
host, with a SHA256SUMS built the same way the release workflow builds it.

  $ mkdir -p build
  $ cat > build/mentat <<'EOF'
  > #!/bin/sh
  > echo 1.2.3
  > EOF
  $ cp build/mentat build/mentatd
  $ chmod 755 build/mentat build/mentatd
  $ dl="$PWD/fixture/releases/download/1.2.3"
  $ mkdir -p "$dl"
  $ tar -czf "$dl/mentat.tar.gz" -C build mentat mentatd
  $ for t in darwin-arm64 darwin-x64 linux-x64 linux-arm64; do
  >   cp "$dl/mentat.tar.gz" "$dl/mentat-$t.tar.gz"
  > done
  $ rm "$dl/mentat.tar.gz"
  $ sums() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
  $ (cd "$dl" && sums mentat-*.tar.gz > SHA256SUMS)

The install: checksum verification passing is what lets it proceed at all (a
mismatch is the tampered.t refusal).

  $ MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 1.2.3 --dir "$PWD/prefix" --no-modify-path | norm
  Installing mentat 1.2.3 (TARGET) to $TESTCASE_ROOT/prefix
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix/mentat
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix/mentatd
  
  Add $TESTCASE_ROOT/prefix to your PATH to use mentat:
    export PATH="$TESTCASE_ROOT/prefix:$PATH"
  
  Get started:
    mentat auth login anthropic   # or openai, google
    mentat                        # open the TUI in your project
  
  Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)

Both binaries landed, nothing else (no staging leftovers), and both execute.

  $ ls "$PWD/prefix"
  mentat
  mentatd
  $ "$PWD/prefix/mentat" --version
  1.2.3
  $ "$PWD/prefix/mentatd" --version
  1.2.3

The second run short-circuits on the installed pair; pointing the seam at a
tree that does not exist proves no fetch happens on that path.

  $ MENTAT_INSTALL_BASE_URL="file://$PWD/absent" sh install.sh \
  >   --version 1.2.3 --dir "$PWD/prefix" --no-modify-path
  mentat 1.2.3 is already installed at $TESTCASE_ROOT/prefix/mentat
