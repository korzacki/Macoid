#!/usr/bin/env bash
# build-repo.sh - build Macoid's native package repo, the same way Termux does it.
#
# WHY THIS IS SLOW (and why installs on the phone are fast):
#   Termux packages are compiled once, for one fixed prefix (/data/data/<app id>/files/usr), and then every install is just
#   "download a .deb and unpack it". Macoid's app id is com.macoid.terminal, so Termux's own packages cannot be reused
#   (their paths are hard-coded to com.termux). They have to be rebuilt for Macoid's prefix ONCE. That is this script.
#   Expect hours and 30-60 GB of disk for the default set per CPU architecture (rust / clang / nodejs / python dominate).
#   Run it on a PC or VPS (Linux x86_64 with Docker) - NOT on the phone and not on every install.
#
# WHAT YOU GET (in ./dist, plain static files - host them anywhere over HTTPS: GitHub Pages, Cloudflare R2/Pages, a VPS ...):
#   dist/bootstrap-<arch>.zip  (+ .sha256)     what the app downloads once on the first "pkg install"
#   dist/apt/dists, dist/apt/pool              the apt repo that "pkg install" pulls .deb files from
# Then set NAT_BASE_URL in app/src/main/assets/lib/native.conf to the URL where dist/ is published and rebuild the APK.
#
# USAGE:   ARCHES="aarch64" ./tools/build-repo.sh            (default: aarch64 = nearly every phone today)
#          ARCHES="aarch64 arm x86_64" PKGS_EXTRA="python nodejs git" ./tools/build-repo.sh
#          FULL=1 ./tools/build-repo.sh                      (also ruby golang rust ffmpeg ...: much longer)
# Re-running continues where it stopped (already built packages are skipped).
#
# NOT TESTED END TO END by the author of this change (it needs Docker and many hours). The prefix patch below is the
# documented way to fork termux-packages; if a step fails, the message says which one. Check the upstream docs:
#   https://github.com/termux/termux-packages/wiki/Building-packages  (see the section about forks / changing the app id)
set -euo pipefail

APP_ID="${APP_ID:-com.macoid.terminal}"
ARCHES="${ARCHES:-aarch64}"
TP_REF="${TP_REF:-master}"
PORT="${PORT:-8765}"
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/dist}"
FULL="${FULL:-0}"

# What the bootstrap itself needs (kept in the zip) ...
BOOT_PKGS="apt dpkg bash dash coreutils diffutils findutils gawk grep gzip less procps psmisc sed tar util-linux ed debianutils \
dos2unix inetutils lsof nano net-tools patch unzip ncurses-utils curl termux-core termux-exec termux-keyring termux-tools"
# ... and what users get with a plain "pkg install" afterwards.
PKGS_EXTRA="${PKGS_EXTRA:-git openssh python python-pip nodejs clang make cmake jq ripgrep rsync vim tmux wget zip htop sqlite libxml2-utils}"
[ "$FULL" = 1 ] && PKGS_EXTRA="$PKGS_EXTRA ruby golang rust ffmpeg imagemagick neovim openjdk-21 php perl lua54"

MODE="${1:-all}"   # all | prepare | build "<pkgs>" | repo | bootstrap   (the GitHub workflow calls the modes one by one)

die() { echo "build-repo: $*" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c   (Debian/Ubuntu: apt install docker.io git python3 curl zip dpkg-dev apt-utils coreutils)"; done; }
TP="$WORK/termux-packages"

prepare() {
  need docker git python3 curl
  docker info >/dev/null 2>&1 || die "Docker is not running / not usable by this user"
  mkdir -p "$WORK" "$OUT"
  if [ ! -d "$TP/.git" ]; then
    echo "==> cloning termux-packages ($TP_REF)"
    git clone --depth 1 --branch "$TP_REF" https://github.com/termux/termux-packages "$TP"
  fi
  echo "==> pointing termux-packages at $APP_ID"
  P="$TP/scripts/properties.sh"
  [ -f "$P" ] || die "$P not found - termux-packages changed its layout, see the upstream fork docs"
  # the variable is called TERMUX_APP__PACKAGE_NAME in current termux-packages (TERMUX_APP_PACKAGE in older ones)
  sed -i -E "s/^(TERMUX_APP__PACKAGE_NAME=).*/\1\"$APP_ID\"/; s/^(TERMUX_APP_PACKAGE=).*/\1\"$APP_ID\"/" "$P"
  grep -q "\"$APP_ID\"" "$P" || die "could not set the app id in $P - set the app package name to $APP_ID by hand, then re-run"
  grep -nE "^(TERMUX_APP__PACKAGE_NAME|TERMUX_APP_PACKAGE|TERMUX__PREFIX|TERMUX_PREFIX)=" "$P" || true
  echo "    prefix must come out as /data/data/$APP_ID/files/usr - Macoid sets PREFIX to exactly that (Sessions.kt)"
}

build() {   # build <pkgs...>   -> .deb files in termux-packages/output
  [ $# -gt 0 ] || die "build: no packages given"
  for arch in $ARCHES; do
    echo "==> building for $arch: $*   (this is the part that takes hours)"
    ( cd "$TP" && ./scripts/run-docker.sh ./build-package.sh -s -a "$arch" "$@" )
  done
}

make_repo() {
  need dpkg-scanpackages apt-ftparchive
  echo "==> creating the apt repo in $OUT/apt"
  rm -rf "$OUT/apt"; mkdir -p "$OUT/apt/pool/main"
  find "$TP/output" -name '*.deb' -exec cp -f {} "$OUT/apt/pool/main/" \;
  ( cd "$OUT/apt"
    for arch in $ARCHES; do
      d="dists/stable/main/binary-$arch"; mkdir -p "$d"
      dpkg-scanpackages --arch "$arch" pool/main /dev/null > "$d/Packages" 2>/dev/null
      gzip -kf "$d/Packages"
    done
    apt-ftparchive \
      -o APT::FTPArchive::Release::Origin=Macoid -o APT::FTPArchive::Release::Label=Macoid \
      -o APT::FTPArchive::Release::Suite=stable -o APT::FTPArchive::Release::Codename=stable \
      -o APT::FTPArchive::Release::Architectures="$ARCHES" -o APT::FTPArchive::Release::Components=main \
      release dists/stable > dists/stable/Release
  )
}

make_bootstrap() {
  need python3 curl zip sha256sum
  echo "==> generating bootstraps"
  ( cd "$OUT" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > "$WORK/http.pid" )
  trap 'kill "$(cat "$WORK/http.pid" 2>/dev/null)" 2>/dev/null || true' EXIT
  sleep 1
  for arch in $ARCHES; do
    ( cd "$WORK" && "$TP/scripts/generate-bootstraps.sh" --architectures "$arch" --repository "http://127.0.0.1:$PORT/apt" ) \
      || die "generate-bootstraps.sh failed for $arch (flags differ between termux-packages versions: run it with --help)"
    z=$(ls -t "$WORK"/bootstrap-"$arch".zip "$TP"/bootstrap-"$arch".zip 2>/dev/null | head -1 || true)
    [ -n "$z" ] || die "bootstrap-$arch.zip was not produced"
    cp -f "$z" "$OUT/bootstrap-$arch.zip"
    ( cd "$OUT" && sha256sum "bootstrap-$arch.zip" | cut -d' ' -f1 > "bootstrap-$arch.zip.sha256" )
  done
}

case "$MODE" in
  prepare)   prepare;;
  build)     shift; prepare; build "$@";;
  repo)      prepare; make_repo;;
  bootstrap) prepare; make_bootstrap;;
  all)       prepare; build $BOOT_PKGS $PKGS_EXTRA; make_repo; make_bootstrap
             echo; echo "Done. Publish the contents of $OUT over HTTPS and set NAT_BASE_URL in lib/native.conf (see README).";;
  boot-pkgs) echo "$BOOT_PKGS";;
  extra-pkgs) echo "$PKGS_EXTRA";;
  *) die "unknown mode '$MODE' (all | prepare | build <pkgs> | repo | bootstrap)";;
esac
