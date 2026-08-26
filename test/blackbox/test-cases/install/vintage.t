A release that predates the mentatd daemon ships an archive without the
mentatd member: the installer conditions the daemon half on the member's
presence, installs the CLI alone with the documented note, and a later
re-run installs again in full — the already-installed short-circuit requires
the pair, so it deliberately never fires for a CLI-only install.

  $ unset GITHUB_PATH
  $ norm() { sed 's/([a-z]*-[a-z0-9]*)/(TARGET)/'; }
  $ mkdir -p build
  $ cat > build/mentat <<'EOF'
  > #!/bin/sh
  > echo 0.9.0
  > EOF
  $ chmod 755 build/mentat
  $ dl="$PWD/fixture/releases/download/0.9.0"
  $ mkdir -p "$dl"
  $ tar -czf "$dl/mentat.tar.gz" -C build mentat
  $ for t in darwin-arm64 darwin-x64 linux-x64 linux-arm64; do
  >   cp "$dl/mentat.tar.gz" "$dl/mentat-$t.tar.gz"
  > done
  $ rm "$dl/mentat.tar.gz"
  $ sums() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
  $ (cd "$dl" && sums mentat-*.tar.gz > SHA256SUMS)

  $ MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 0.9.0 --dir "$PWD/prefix" --no-modify-path | norm
  Installing mentat 0.9.0 (TARGET) to $TESTCASE_ROOT/prefix
  Installed 0.9.0 -> $TESTCASE_ROOT/prefix/mentat
  note: release 0.9.0 predates the mentatd daemon; only mentat was installed
  
  Add $TESTCASE_ROOT/prefix to your PATH to use mentat:
    export PATH="$TESTCASE_ROOT/prefix:$PATH"
  
  Get started:
    mentat auth login anthropic   # or openai, google
    mentat                        # open the TUI in your project
  
  Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)

Only the CLI landed.

  $ ls "$PWD/prefix"
  mentat

Re-running does not short-circuit: with no mentatd beside the CLI the pair
check fails, so the installer runs in full again.

  $ MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 0.9.0 --dir "$PWD/prefix" --no-modify-path | norm
  Installing mentat 0.9.0 (TARGET) to $TESTCASE_ROOT/prefix
  Installed 0.9.0 -> $TESTCASE_ROOT/prefix/mentat
  note: release 0.9.0 predates the mentatd daemon; only mentat was installed
  
  Add $TESTCASE_ROOT/prefix to your PATH to use mentat:
    export PATH="$TESTCASE_ROOT/prefix:$PATH"
  
  Get started:
    mentat auth login anthropic   # or openai, google
    mentat                        # open the TUI in your project
  
  Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)
