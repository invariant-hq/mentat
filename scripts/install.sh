#!/bin/sh
# Install mentat, the OCaml coding agent.
#
#   curl -fsSL https://raw.githubusercontent.com/invariant-hq/mentat/main/scripts/install.sh | sh
#
# Options (flags or environment variables):
#   -v, --version X.Y.Z    install a specific release  (MENTAT_VERSION)
#   -d, --dir DIR          install directory           (MENTAT_INSTALL_DIR,
#                          default ~/.local/bin)
#       --no-modify-path   never edit shell rc files
#
# Downloads the release archive for this platform from GitHub Releases,
# verifies it against the release's SHA256SUMS, and installs atomically.
# The whole script is a function invoked on the last line so a truncated
# download cannot execute a partial script.

set -eu

REPO="invariant-hq/mentat"
GITHUB="https://github.com"

# Test seam: MENTAT_INSTALL_BASE_URL replaces the GitHub release root in the
# download URLs so the test suite can install from a local file:// fixture
# tree shaped like <root>/releases/download/<version>/, and file transfers
# are then permitted alongside https. Unset (every real install), both
# values keep the GitHub behavior documented above, byte for byte.
RELEASE_ROOT="$GITHUB/$REPO"
FETCH_PROTO='=https'
if [ -n "${MENTAT_INSTALL_BASE_URL:-}" ]; then
  RELEASE_ROOT="$MENTAT_INSTALL_BASE_URL"
  FETCH_PROTO='=https,file'
fi

usage() {
  cat <<'EOF'
Install mentat, the OCaml coding agent.

  curl -fsSL https://raw.githubusercontent.com/invariant-hq/mentat/main/scripts/install.sh | sh

Options (flags or environment variables):
  -v, --version X.Y.Z    install a specific release  (MENTAT_VERSION)
  -d, --dir DIR          install directory           (MENTAT_INSTALL_DIR,
                         default ~/.local/bin)
      --no-modify-path   never edit shell rc files
EOF
}

say() { printf '%s\n' "$*"; }
err() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" > /dev/null 2>&1 || err "required command not found: $1"
}

# curl is preferred; wget keeps the installer usable on images that ship only
# BusyBox. BusyBox wget can fetch a known URL but cannot report a redirect
# target or refuse a plaintext redirect, so the GNU build is detected once and
# the difference is raised where it matters instead of producing a bad URL.
select_downloader() {
  if command -v curl > /dev/null 2>&1; then
    downloader=curl
  elif command -v wget > /dev/null 2>&1; then
    downloader=wget
    if wget --help 2>&1 | grep -q -- '--https-only'; then
      wget_gnu=1
    fi
  else
    err "neither curl nor wget found; install one and re-run"
  fi
}

fetch() {
  if [ "$downloader" = curl ]; then
    curl -fsSL --proto "$FETCH_PROTO" --tlsv1.2 -o "$2" "$1"
  elif [ "$wget_gnu" = 1 ]; then
    wget -q --https-only -O "$2" "$1"
  else
    wget -q -O "$2" "$1"
  fi
}

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    err "neither sha256sum nor shasum found; cannot verify download"
  fi
}

# A version becomes part of a download URL, so accept only the shape a release
# tag can have: the X.Y.Z prefix the release workflow enforces, plus an
# optional suffix. This also rejects the HTML a captive portal or a blocked
# region returns in place of the redirect that names the latest release.
version_ok() {
  case "$1" in
  *[!A-Za-z0-9.+-]*) return 1 ;;
  [0-9]*.[0-9]*.[0-9]*) return 0 ;;
  esac
  return 1
}

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
  Darwin)
    # A binary running under Rosetta reports x86_64; the machine is arm64.
    if [ "$arch" = "x86_64" ] \
      && [ "$(sysctl -n sysctl.proc_translated 2> /dev/null || echo 0)" = "1" ]; then
      arch=arm64
    fi
    case "$arch" in
    arm64) target=darwin-arm64 ;;
    x86_64) target=darwin-x64 ;;
    *) err "unsupported macOS architecture: $arch" ;;
    esac
    ;;
  Linux)
    # The Linux binaries are fully static, so the C library on the host does
    # not select the archive.
    case "$arch" in
    x86_64 | amd64) target=linux-x64 ;;
    aarch64 | arm64) target=linux-arm64 ;;
    *) err "unsupported Linux architecture: $arch" ;;
    esac
    ;;
  MINGW* | MSYS* | CYGWIN*)
    err "Windows is not supported yet; use WSL and the Linux binary"
    ;;
  *)
    err "unsupported platform: $os"
    ;;
  esac
  printf '%s' "$target"
}

# Resolve the concrete version tag for a release, following GitHub's
# "latest" redirect so we never need the rate-limited API.
resolve_version() {
  if [ -n "$version" ]; then
    printf '%s' "$version"
    return
  fi
  url="$RELEASE_ROOT/releases/latest"
  if [ "$downloader" = curl ]; then
    location="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      --proto "$FETCH_PROTO" --tlsv1.2 "$url")" || err "cannot reach $url"
  else
    [ "$wget_gnu" = 1 ] || err "this wget cannot report the latest release;
pass --version X.Y.Z, or install curl or GNU wget"
    location="$(wget -S --spider "$url" 2>&1 \
      | sed -n 's/^[[:space:]]*[Ll]ocation:[[:space:]]*//p' | tail -n 1)"
    # GNU wget prints the redirect it is about to take as "URL [following]".
    location="${location%% *}"
  fi
  tag="${location##*/}"
  version_ok "$tag" || err "cannot determine the latest release of $REPO
$url resolved to \"$tag\", which is not a version tag. Pass --version X.Y.Z
to install a known release."
  printf '%s' "$tag"
}

modify_path() {
  case ":$PATH:" in
  *":$install_dir:"*) return 0 ;;
  esac

  # --no-modify-path means no path modification anywhere, the GitHub Actions
  # file included; a workflow that wants the append simply omits the flag.
  if [ "$no_modify_path" = 1 ]; then
    say ""
    say "Add $install_dir to your PATH to use mentat:"
    say "  export PATH=\"$install_dir:\$PATH\""
    return 0
  fi

  # Make the freshly installed binary visible to GitHub Actions steps.
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$install_dir" >> "$GITHUB_PATH"
    return 0
  fi

  case "$install_dir" in
  *[!A-Za-z0-9_./-]*)
    say ""
    say "The install directory requires shell quoting; add it to PATH manually."
    return 0
    ;;
  esac

  shell_name="$(basename "${SHELL:-sh}")"
  rc=""
  line="export PATH=\"$install_dir:\$PATH\""
  case "$shell_name" in
  zsh) rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash)
    for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
      if [ -f "$f" ]; then
        rc="$f"
        break
      fi
    done
    rc="${rc:-$HOME/.bashrc}"
    ;;
  fish)
    rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
    line="fish_add_path $install_dir"
    ;;
  *) rc="$HOME/.profile" ;;
  esac

  if [ -f "$rc" ] && grep -Fq "$line" "$rc"; then
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  printf '\n# Added by the mentat installer\n%s\n' "$line" >> "$rc"
  say "Added $install_dir to PATH in $rc; restart your shell to pick it up."
}

# Under sudo, $HOME is usually root's: the binary would land in
# /root/.local/bin and the shell that asked for it would never see the
# command. An explicit install directory states where the binary goes, so
# only the home-directory default is refused. Plain root, as in a container
# or CI, sets no SUDO_USER and is unaffected.
check_sudo() {
  [ "$(id -u)" = 0 ] || return 0
  case "${SUDO_USER:-}" in
  '' | root) return 0 ;;
  esac

  if [ "$dir_given" = 0 ] && [ -z "${MENTAT_INSTALL_ALLOW_SUDO:-}" ]; then
    err "refusing to install under sudo

mentat installs into your home directory and does not need root. Re-run
without sudo:

  curl -fsSL https://raw.githubusercontent.com/invariant-hq/mentat/main/scripts/install.sh | sh

To install for everyone on the machine, name the directory instead:

  curl -fsSL https://raw.githubusercontent.com/invariant-hq/mentat/main/scripts/install.sh | \\
    sudo sh -s -- --dir /usr/local/bin

To install for the root user anyway, set MENTAT_INSTALL_ALLOW_SUDO=1."
  fi

  # Startup files reachable from here are root's, not those of the user who
  # asked for the install.
  no_modify_path=1
}

main() {
  version="${MENTAT_VERSION:-}"
  install_dir="${MENTAT_INSTALL_DIR:-$HOME/.local/bin}"
  no_modify_path=0
  downloader=""
  wget_gnu=0
  if [ -n "${MENTAT_INSTALL_DIR:-}" ]; then
    dir_given=1
  else
    dir_given=0
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
    -v | --version)
      [ $# -ge 2 ] || err "$1 requires an argument"
      version="$2"
      shift 2
      ;;
    -d | --dir)
      [ $# -ge 2 ] || err "$1 requires an argument"
      install_dir="$2"
      dir_given=1
      shift 2
      ;;
    --no-modify-path)
      no_modify_path=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "unknown option: $1 (try --help)"
      ;;
    esac
  done

  need uname
  need id
  need tar
  need mktemp
  need awk
  select_downloader
  check_sudo

  # Release tags carry no leading "v"; accept the habit rather than failing
  # the download with a bare 404.
  version="${version#v}"
  if [ -n "$version" ]; then
    version_ok "$version" || err "invalid version: $version (expected X.Y.Z)"
  fi

  target="$(detect_target)"
  version="$(resolve_version)"
  archive="mentat-$target.tar.gz"
  base="$RELEASE_ROOT/releases/download/$version"

  installed="$install_dir/mentat"
  installed_d="$install_dir/mentatd"
  if [ -x "$installed" ] && [ -x "$installed_d" ] \
    && [ "$("$installed" --version 2> /dev/null || true)" = "$version" ] \
    && [ "$("$installed_d" --version 2> /dev/null || true)" = "$version" ]; then
    say "mentat $version is already installed at $installed"
    exit 0
  fi

  # Fail before spending a download on a directory we cannot publish into.
  mkdir -p "$install_dir" || err "cannot create install directory: $install_dir"
  [ -w "$install_dir" ] || err "install directory is not writable: $install_dir
Pick another with --dir, or re-run under sudo with an explicit --dir."

  say "Installing mentat $version ($target) to $install_dir"

  tmp="$(mktemp -d)"
  staged="$install_dir/.mentat.$$"
  staged_d="$install_dir/.mentatd.$$"
  trap 'rm -rf "$tmp"; rm -f "$staged" "$staged_d"' EXIT INT TERM

  fetch "$base/$archive" "$tmp/$archive" || err "cannot download $base/$archive
Check that release $version exists and publishes a $target archive, and that
this network reaches github.com."
  fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" \
    || err "cannot download $base/SHA256SUMS"

  expected="$(awk -v f="$archive" '$2 == f { print $1 }' "$tmp/SHA256SUMS")"
  [ -n "$expected" ] || err "no checksum for $archive in SHA256SUMS"
  actual="$(sha256_of "$tmp/$archive")"
  if [ "$actual" != "$expected" ]; then
    err "checksum mismatch for $archive
  expected: $expected
  actual:   $actual
The download may be corrupted or tampered with; not installing."
  fi

  tar -xzf "$tmp/$archive" -C "$tmp"
  [ -f "$tmp/mentat" ] || err "archive did not contain a mentat binary"
  # The archive's own contents are the vintage signal: releases before the
  # daemon ship no mentatd, and pinning one with --version must stay
  # installable — the mentatd half of everything below is conditioned on the
  # member's presence, never required.
  has_mentatd=false
  [ -f "$tmp/mentatd" ] && has_mentatd=true

  # Stage inside the destination directory first so the final renames are
  # atomic even when $tmp is on another filesystem, and so a running mentat
  # keeps the executable it started from.
  chmod 755 "$tmp/mentat"
  cp -f "$tmp/mentat" "$staged"
  if [ "$has_mentatd" = true ]; then
    chmod 755 "$tmp/mentatd"
    cp -f "$tmp/mentatd" "$staged_d"
  fi

  # Run the staged copies before publishing them. They sit on the destination
  # filesystem, so this is the exec check the final path would get, and a
  # binary that cannot run here never replaces a working install.
  reported="$("$staged" --version 2> /dev/null || true)"
  [ -n "$reported" ] || err "the $target binary does not run on this machine
Nothing was installed. Please report this with the output of: uname -sm"
  if [ "$has_mentatd" = true ]; then
    reported_d="$("$staged_d" --version 2> /dev/null || true)"
    [ -n "$reported_d" ] || err "the $target mentatd binary does not run on this machine
Nothing was installed. Please report this with the output of: uname -sm"
  fi

  # Two renames, not one: POSIX cannot publish a pair atomically. Each rename
  # is itself atomic, and the window where a new mentat sits beside an old
  # mentatd is harmless — the pair carries one version stamp, so a client
  # catching the skew is refused loudly by the daemon identity check rather
  # than silently attached to a mismatched daemon.
  mv -f "$staged" "$installed"
  say "Installed $reported -> $installed"
  if [ "$has_mentatd" = true ]; then
    mv -f "$staged_d" "$installed_d"
    say "Installed $reported_d -> $installed_d"
  else
    say "note: release $version predates the mentatd daemon; only mentat was installed"
  fi
  modify_path

  say ""
  say "Get started:"
  say "  mentat auth login anthropic   # or openai, google"
  say "  mentat                        # open the TUI in your project"
  say ""
  say "Shell completions: mentat completion zsh|bash|pwsh (see mentat completion --help)"
}

main "$@"
