An archive whose checksum does not match SHA256SUMS is refused loudly and
nothing is installed: the published sum (all zeros here) is quoted as
expected, the archive's real hash as actual, and the prefix stays empty.

  $ norm() { sed -e 's/([a-z]*-[a-z0-9]*)/(TARGET)/' \
  >              -e 's/mentat-[a-z]*-[a-z0-9]*\.tar\.gz/mentat-TARGET.tar.gz/' \
  >              -e '/actual:/s/[0-9a-f]\{64\}/HASH/'; }
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
  $ for t in darwin-arm64 darwin-x64 linux-x64 linux-arm64; do
  >   printf '%064d  mentat-%s.tar.gz\n' 0 "$t"
  > done > "$dl/SHA256SUMS"

  $ MENTAT_INSTALL_BASE_URL="file://$PWD/fixture" sh install.sh \
  >   --version 1.2.3 --dir "$PWD/prefix" --no-modify-path >out 2>err
  [1]
  $ norm < out
  Installing mentat 1.2.3 (TARGET) to $TESTCASE_ROOT/prefix
  $ norm < err
  install.sh: checksum mismatch for mentat-TARGET.tar.gz
    expected: 0000000000000000000000000000000000000000000000000000000000000000
    actual:   HASH
  The download may be corrupted or tampered with; not installing.

Nothing was installed, and the staged copies were cleaned up.

  $ ls "$PWD/prefix"
