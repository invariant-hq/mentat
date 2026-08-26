Without --no-modify-path the installer appends one PATH line to the shell's
rc file (zsh here; HOME is the harness sandbox) and reports it; a later
install finds the line already present and never appends a second copy. In
GitHub Actions ($GITHUB_PATH exported) the append goes there instead of any
rc file — unless --no-modify-path forbids path modification anywhere.

  $ unset GITHUB_PATH
  $ unset ZDOTDIR
  $ SHELL=/bin/zsh
  $ export SHELL
  $ norm() { sed 's/([a-z]*-[a-z0-9]*)/(TARGET)/'; }
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

  $ MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 1.2.3 --dir "$PWD/prefix" | norm
  Installing mentat 1.2.3 (TARGET) to $TESTCASE_ROOT/prefix
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix/mentat
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix/mentatd
  Added $TESTCASE_ROOT/prefix to PATH in $TESTCASE_ROOT/home/.zshrc; restart your shell to pick it up.
  
  Get started:
    mentat auth login anthropic   # or openai, google
    mentat                        # open the TUI in your project
  
  Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)

  $ cat home/.zshrc
  
  # Added by the mentat installer
  export PATH="$TESTCASE_ROOT/prefix:$PATH"

Reinstall (binaries removed so the short-circuit stays out of the way): the
line is already in the rc file, so nothing is appended and nothing is said.

  $ rm prefix/mentat prefix/mentatd
  $ MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 1.2.3 --dir "$PWD/prefix" | norm
  Installing mentat 1.2.3 (TARGET) to $TESTCASE_ROOT/prefix
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix/mentat
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix/mentatd
  
  Get started:
    mentat auth login anthropic   # or openai, google
    mentat                        # open the TUI in your project
  
  Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)

  $ grep -c 'Added by the mentat installer' home/.zshrc
  1

In GitHub Actions the directory is recorded in $GITHUB_PATH instead of any
rc file, silently; the rc file gains nothing new.

  $ : > gh-path
  $ GITHUB_PATH="$PWD/gh-path" MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 1.2.3 --dir "$PWD/prefix2" | norm
  Installing mentat 1.2.3 (TARGET) to $TESTCASE_ROOT/prefix2
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix2/mentat
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix2/mentatd
  
  Get started:
    mentat auth login anthropic   # or openai, google
    mentat                        # open the TUI in your project
  
  Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)
  $ cat gh-path
  $TESTCASE_ROOT/prefix2
  $ grep -c 'Added by the mentat installer' home/.zshrc
  1

--no-modify-path wins over $GITHUB_PATH: no path modification anywhere, so
the Actions file stays empty and the manual hint is printed instead.

  $ : > gh-path
  $ GITHUB_PATH="$PWD/gh-path" MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 1.2.3 --dir "$PWD/prefix3" --no-modify-path | norm
  Installing mentat 1.2.3 (TARGET) to $TESTCASE_ROOT/prefix3
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix3/mentat
  Installed 1.2.3 -> $TESTCASE_ROOT/prefix3/mentatd
  
  Add $TESTCASE_ROOT/prefix3 to your PATH to use mentat:
    export PATH="$TESTCASE_ROOT/prefix3:$PATH"
  
  Get started:
    mentat auth login anthropic   # or openai, google
    mentat                        # open the TUI in your project
  
  Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)
  $ cat gh-path
