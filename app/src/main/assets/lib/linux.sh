# Local Linux engine: Alpine Linux inside proot, running ON the phone.
# This is the fast installer backend - no GitHub runner, no queue, no VM boot, no upload/download of caches.
#   pip / npm / gem / cargo / go / apk / apt / brew installs land in $LXROOT and simply stay there.
# Sourced by pkg, lx, shim.sh and brew. Needs $MACOID (set by the app).
. "$MACOID/lib/common.sh"

LX="$MACOID/linux"
LXROOT="$LX/alpine"
LXPROOT="$LX/proot"
LXBINS="$LX/bins"                 # command names that exist inside Linux
LXWRAP="$LX/wrap"                 # one tiny launcher per Linux command; this folder is on PATH, so new commands work at once (like Termux)
LXSTAMP="$LX/index.stamp"         # when the apk package index was last refreshed
LX_BIN_DIRS="usr/local/bin usr/bin bin usr/sbin sbin root/.local/bin root/.cargo/bin root/go/bin"
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
  mkdir -p "$LXROOT/etc" "$LXROOT/root" "$LXROOT/tmp" "$LXROOT/proc" "$LXROOT/sys" "$LXROOT/dev" "$LXROOT/var/cache/apk"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$LXROOT/etc/resolv.conf"
  printf '127.0.0.1 localhost\n::1 localhost\n' > "$LXROOT/etc/hosts"
  # some phones need seccomp off for proot; probe once and remember
  if ! _lx_proot true >/dev/null 2>&1; then
    : > "$LX/noseccomp"
    _lx_proot true >/dev/null 2>&1 || { echo "macoid: the Linux engine does not start on this phone" >&2; rm -f "$LX/noseccomp"; return 1; }
  fi
  lx_apk_update >/dev/null 2>&1
  lx_sync_bins
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
    go|gofmt|golang) echo go;;
    rg) echo ripgrep;;
    nvim) echo neovim;;
    openjdk|jdk) echo openjdk17;;
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
  __lx_p=$(lx_pkgs "$1")
  [ -n "$__lx_p" ] || return 1
  echo "[macoid] installing $__lx_p (apk)..." >&2
  lx_apk_add $__lx_p >&2 || return 1
  lx_has "$1"
}

# ---- package index: refreshed at most every 12 h and kept on disk, so an install does not re-download it each time
lx_apk_update() {
  __lx_o="$TMPDIR/apk-update.$$"
  if _lx_proot /sbin/apk update >"$__lx_o" 2>&1; then date +%s > "$LXSTAMP"; rm -f "$__lx_o"; return 0; fi
  cat "$__lx_o" >&2; rm -f "$__lx_o"; return 1
}
lx_index_fresh() {
  [ -s "$LXSTAMP" ] || return 1
  __lx_t=$(cat "$LXSTAMP" 2>/dev/null); __lx_n=$(date +%s)
  case "$__lx_t" in ''|*[!0-9]*) return 1;; esac
  [ "$__lx_n" -ge "$__lx_t" ] && [ $((__lx_n - __lx_t)) -lt 43200 ]
}

# lx_apk_add <pkg...>: install with apk. Prints apk's progress live and its errors afterwards.
#   returns 0 = installed; otherwise 1, and LX_APK_MISSING=1 when the cause is "no such package" (not a network/engine problem)
lx_apk_add() {
  LX_APK_MISSING=0; __lx_upd=0; __lx_uf=0
  mkdir -p "$LXROOT/var/cache/apk" "$TMPDIR"
  if ! lx_index_fresh; then lx_apk_update && __lx_upd=1 || __lx_uf=1; fi
  __lx_e="$TMPDIR/apk-add.$$"
  _lx_proot /sbin/apk add "$@" 2>"$__lx_e"; __lx_rc=$?
  if [ $__lx_rc -ne 0 ] && [ $__lx_upd = 0 ] && grep -q -e 'no such package' -e 'unable to select' "$__lx_e" 2>/dev/null; then
    if lx_apk_update; then _lx_proot /sbin/apk add "$@" 2>"$__lx_e"; __lx_rc=$?; __lx_uf=0; else __lx_uf=1; fi
  fi
  if [ $__lx_rc -ne 0 ]; then
    # "no such package" while the index could not be downloaded just means "no internet": do not call it a missing package
    [ $__lx_uf = 0 ] && grep -q -e 'no such package' -e 'unable to select' "$__lx_e" 2>/dev/null && LX_APK_MISSING=1
    cat "$__lx_e" >&2
    [ $__lx_uf = 1 ] && echo "[macoid] the package index could not be downloaded - check your internet connection." >&2
  else
    lx_sync_bins
  fi
  rm -f "$__lx_e"; return $__lx_rc
}

# lx_sync_bins: register every command Linux has. Each one gets a small launcher in $LXWRAP (on PATH), so a freshly
# installed command works immediately, also inside scripts, pipes and xargs - no shell restart needed.
lx_sync_bins() {
  mkdir -p "$LXWRAP" "$TMPDIR"
  { for __lx_d in $LX_BIN_DIRS; do
      [ -d "$LXROOT/$__lx_d" ] && ls -1 "$LXROOT/$__lx_d" 2>/dev/null
    done; } | grep -E '^[A-Za-z0-9_+.-]+$' | sort -u > "$LXBINS.new" && mv "$LXBINS.new" "$LXBINS" || return 1
  for __lx_f in "$LXWRAP"/*; do      # launchers whose command is gone
    [ -e "$__lx_f" ] || continue
    grep -qx -- "${__lx_f##*/}" "$LXBINS" 2>/dev/null || rm -f "$__lx_f"
  done
  while IFS= read -r __lx_n; do      # launchers for new commands (names Android or Macoid already provide are left alone)
    [ -f "$LXWRAP/$__lx_n" ] && continue
    [ -e "/system/bin/$__lx_n" ] || [ -e "/system/xbin/$__lx_n" ] || [ -e "$MACOID/bin/$__lx_n" ] && continue
    printf '#!/system/bin/sh\nexec /system/bin/sh "$MACOID/lib/shim.sh" %s "$@"\n' "$__lx_n" > "$LXWRAP/$__lx_n"
    chmod 755 "$LXWRAP/$__lx_n"
  done < "$LXBINS"
  return 0
}

# lx_after <tool> [args]: package managers that were just run may have added commands (pip, npm -g, cargo install ...)
lx_after() {
  case "$1" in pip|pip3|pip3.*|pipx|uv|uvx|npm|pnpm|yarn|gem|bundle|bundler|cargo|go|cpan|luarocks|composer) lx_sync_bins;; esac
  return 0
}

lx_reset() { rm -rf "$LXROOT" "$LXBINS" "$LXWRAP" "$LXSTAMP" "$LX/noseccomp"; }
