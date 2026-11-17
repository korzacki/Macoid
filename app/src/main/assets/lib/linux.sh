# Local Linux engine: Alpine Linux inside proot, running ON the phone.
# This is the fast installer backend - no GitHub runner, no queue, no VM boot, no upload/download of caches.
#   pip / npm / gem / cargo / go / apk / apt / brew installs land in $LXROOT and simply stay there.
# Sourced by pkg, lx, shim.sh and brew. Needs $MACOID (set by the app).
. "$MACOID/lib/common.sh"

LX="$MACOID/linux"
LXROOT="$LX/alpine"
LXPROOT="$LX/proot"
LXBINS="$LX/bins"                 # command names that exist inside Linux (macoid.rc turns them into aliases)
LX_PROOT_VER=v5.3.0
LX_ALPINE_FALLBACK=3.20.3

lx_arch() {   # prints "<proot-arch> <alpine-arch>"
  case "$(uname -m 2>/dev/null)" in
    aarch64|arm64) echo "aarch64 aarch64";;
    armv7*|armv8l|arm*) echo "arm armv7";;
    x86_64|amd64) echo "x86_64 x86_64";;
    *) return 1;;
  esac
}

lx_ready() { [ -x "$LXPROOT" ] && [ -e "$LXROOT/bin/busybox" ]; }

lx_fetch() {   # url dest  (wget is the app's own binary-safe downloader)
  /system/bin/sh "$MACOID/bin/wget" -q -O "$2.part" "$1" && [ -s "$2.part" ] && mv "$2.part" "$2" || { rm -f "$2.part"; return 1; }
}

# One-time setup (~1 MB engine + ~3.5 MB root filesystem). Safe to call again: it returns at once when ready.
lx_setup() {
  lx_ready && return 0
  _arch=$(lx_arch) || { echo "macoid: this CPU ($(uname -m)) is not supported by the local Linux engine" >&2; return 1; }
  _pa=${_arch% *}; _aa=${_arch#* }
  mkdir -p "$LX" "$TMPDIR"
  if [ ! -x "$LXPROOT" ]; then
    echo "[macoid] first run: downloading the Linux engine (one time only)..." >&2
    lx_fetch "https://github.com/proot-me/proot/releases/download/$LX_PROOT_VER/proot-$LX_PROOT_VER-$_pa-static" "$LXPROOT" \
      || { echo "macoid: could not download proot (check your internet)" >&2; return 1; }
    chmod 755 "$LXPROOT"
  fi
  if [ ! -e "$LXROOT/bin/busybox" ]; then
    echo "[macoid] first run: downloading Alpine Linux (one time only)..." >&2
    _base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$_aa"
    _f=$(/system/bin/sh "$MACOID/bin/wget" -q -O - "$_base/latest-releases.yaml" 2>/dev/null \
         | sed -n 's/^ *file: *\(alpine-minirootfs-[^ ]*\.tar\.gz\) *$/\1/p' | head -1)
    [ -n "$_f" ] || { _f="alpine-minirootfs-$LX_ALPINE_FALLBACK-$_aa.tar.gz"; _base="https://dl-cdn.alpinelinux.org/alpine/v${LX_ALPINE_FALLBACK%.*}/releases/$_aa"; }
    _tgz="$LX/rootfs.tar.gz"
    lx_fetch "$_base/$_f" "$_tgz" || { echo "macoid: could not download Alpine Linux (check your internet)" >&2; return 1; }
    rm -rf "$LXROOT"; mkdir -p "$LXROOT"
    tar -xzf "$_tgz" -C "$LXROOT" --exclude='./dev/*' 2>/dev/null
    rm -f "$_tgz"
    [ -e "$LXROOT/bin/busybox" ] || { echo "macoid: unpacking Alpine failed" >&2; rm -rf "$LXROOT"; return 1; }
  fi
  mkdir -p "$LXROOT/etc" "$LXROOT/root" "$LXROOT/tmp" "$LXROOT/proc" "$LXROOT/sys" "$LXROOT/dev"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$LXROOT/etc/resolv.conf"
  printf '127.0.0.1 localhost\n::1 localhost\n' > "$LXROOT/etc/hosts"
  # some phones need seccomp off for proot; probe once and remember
  if ! _lx_proot true >/dev/null 2>&1; then
    : > "$LX/noseccomp"
    _lx_proot true >/dev/null 2>&1 || { echo "macoid: the Linux engine does not start on this phone" >&2; rm -f "$LX/noseccomp"; return 1; }
  fi
  _lx_proot /sbin/apk update >/dev/null 2>&1
  echo "[macoid] Linux ready (Alpine, runs on this phone)." >&2
}

# raw proot call: _lx_proot <cmd> [args]   (runs as fake root inside the Alpine root filesystem)
_lx_proot() {
  [ -f "$LX/noseccomp" ] && export PROOT_NO_SECCOMP=1
  # same paths inside and outside, so project files behave the same; add the current folder if it is outside $HOME
  _lx_extra=""
  case "$PWD/" in "$HOME"/*) ;; *) [ -d "$PWD" ] && _lx_extra="-b $PWD";; esac
  [ -d /storage ] && _lx_extra="$_lx_extra -b /storage"
  PROOT_TMP_DIR="$TMPDIR" "$LXPROOT" --link2symlink -0 --kill-on-exit -r "$LXROOT" \
    -b /dev -b /proc -b /sys -b "$HOME" $_lx_extra \
    -w "$PWD" \
    /usr/bin/env -i HOME=/root USER=root LOGNAME=root SHELL=/bin/sh \
      TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-}" LANG=C.UTF-8 TMPDIR=/tmp \
      PATH=/root/.local/bin:/root/.cargo/bin:/root/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      PIP_BREAK_SYSTEM_PACKAGES=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONUNBUFFERED=1 \
      MACOID_LINUX=1 \
      "$@"
}

# lx_run <cmd> [args]  - run a command inside Linux (sets up on first use)
lx_run() { lx_setup || return 1; _lx_proot "$@"; }

# lx_has <name>: does this command exist inside Linux?
lx_has() {
  for _d in usr/local/bin usr/bin bin usr/sbin sbin root/.local/bin root/.cargo/bin root/go/bin; do
    [ -x "$LXROOT/$_d/$1" ] || [ -L "$LXROOT/$_d/$1" ] && return 0
  done
  return 1
}

# lx_pkgs <tool>: Alpine packages that provide a command we know about (empty = unknown)
lx_pkgs() {
  case "$1" in
    python|python3|python3.*|pydoc3|pydoc) echo python3;;
    pip|pip3) echo "python3 py3-pip";;
    pipx) echo "python3 py3-pip pipx";;
    virtualenv) echo "python3 py3-virtualenv";;
    uv|uvx) echo uv;;
    node|nodejs|npm|npx|corepack) echo "nodejs npm";;
    yarn) echo "nodejs npm yarn";;
    pnpm) echo "nodejs npm pnpm";;
    ruby|irb|gem|bundle|bundler|rake|erb|rdoc|ri) echo "ruby ruby-bundler";;
    cargo|rustc|rustfmt|rustup) echo "cargo rust";;
    go|gofmt) echo go;;
    gcc|g++|cc|c++|make|ld|ar|as|nm|strip|objdump|ranlib) echo "build-base";;
    clang|clang++) echo "clang";;
    cmake) echo cmake;;
    perl) echo perl;;
    php) echo php83;;
    lua|lua5.4) echo lua5.4;;
    java|javac|jar) echo openjdk17;;
    ssh|scp|sftp|ssh-keygen) echo openssh-client;;
    rsync) echo rsync;;
    tmux) echo tmux;;
    htop) echo htop;;
    vim) echo vim;;
    emacs) echo emacs-nox;;
    ffmpeg) echo ffmpeg;;
    sqlite3) echo sqlite;;
    jq) echo jq;;
    llvm-*) echo llvm;;
    xmllint) echo libxml2-utils;;
    xsltproc) echo libxslt;;
    magick|identify|mogrify) echo imagemagick;;
    awk|patch|telnet|nc|diff|cmp|xxd|column|rev|tac|bc|dc|nl|od|hexdump|which|watch|expand|unexpand|fold|fmt|comm|join|split|csplit|md5sum|sha1sum|sha256sum|sha512sum|cpio|bzip2|bunzip2|xz|unxz|lzma|unzip|zip) echo busybox;;
    *) echo "";;
  esac
}

# lx_ensure <tool>: install the package that provides <tool> if it is missing (fast: apk). 0 = tool usable now
lx_ensure() {
  lx_setup || return 1
  lx_has "$1" && return 0
  _p=$(lx_pkgs "$1")
  [ -n "$_p" ] || return 1
  echo "[macoid] installing $_p (apk)..." >&2
  _lx_proot /sbin/apk add --no-cache $_p >&2 || return 1
  lx_sync_bins
  lx_has "$1"
}

# lx_sync_bins: remember every command Linux has, so the Mac-style shell can start them (after restarting the shell)
lx_sync_bins() {
  { for _d in usr/local/bin usr/bin bin usr/sbin sbin root/.local/bin root/.cargo/bin root/go/bin; do
      [ -d "$LXROOT/$_d" ] && ls -1 "$LXROOT/$_d" 2>/dev/null
    done; } | grep -E '^[A-Za-z0-9_+.-]+$' | sort -u > "$LXBINS.new" && mv "$LXBINS.new" "$LXBINS"
}

lx_reset() { rm -rf "$LXROOT" "$LXBINS" "$LX/noseccomp"; }
