#!/bin/sh
# Build a fully static musl mentat binary. Runs inside an Alpine container
# with the checkout mounted at /src:
#
#   docker run --rm -v "$PWD:/src" \
#     -v mentat-dune-cache:/root/.cache/dune \
#     alpine:3.21 sh /src/scripts/release/alpine-build.sh
#
# Requires dune.lock/ to exist in the checkout (run `dune pkg lock` first).
# Leaves the binaries at dist/mentat and dist/mentatd. The mounted checkout is
# written to (_build, dist) — use a disposable checkout, not a working tree.
set -eux

apk add --no-cache build-base ocaml git curl bash tar gzip unzip patch \
  coreutils linux-headers pkgconf ca-certificates gmp-dev gmp-static

# Alpine's packaged dune is too old for `(lang dune 3.22)` + package
# management, and get.dune.build has no musl/arm64 binaries, so bootstrap
# dune from source. Locked packages (the mosaic stack) invoke `dune`
# themselves during their build, so it must land on PATH.
# The version is normally injected by release.yml (docker run -e).
DUNE_VERSION="${DUNE_VERSION:-3.23.1}"
mkdir -p /opt/dune && cd /opt/dune
curl -fsSL --proto '=https' --tlsv1.2 \
  "https://github.com/ocaml/dune/archive/refs/tags/${DUNE_VERSION}.tar.gz" \
  | tar xz --strip-components=1
# bootstrap.ml leaves the real binary in _boot/; the root dune.exe is a
# wrapper script with a relative path that breaks once installed.
ocaml boot/bootstrap.ml
install -m 755 _boot/dune.exe /usr/local/bin/dune
dune --version

cd /src
[ -d dune.lock ] || {
  echo "alpine-build.sh: dune.lock/ missing; run dune pkg lock first" >&2
  exit 1
}

# bytesrw's sysrandom stub calls getentropy(), which musl declares in
# unistd.h (glibc: sys/random.h, which is all the stub includes on Linux);
# GCC 14 makes the resulting implicit declaration a hard error. Force the
# include for every C compile until bytesrw fixes it upstream.
export OCAMLPARAM="_,ccopt=-include unistd.h"
sh scripts/release/link-workspace.sh > /tmp/dune-workspace-release
dune build --workspace /tmp/dune-workspace-release \
  _build/default/bin/main.exe _build/default/bin/mentatd/main.exe

mkdir -p dist
cp _build/default/bin/main.exe dist/mentat
cp _build/default/bin/mentatd/main.exe dist/mentatd
