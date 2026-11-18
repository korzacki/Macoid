# Real Linux on the phone (4.0): a full distro in proot, running locally. No GitHub runner, no cloud.
#   debian  (default)  Debian 13 "trixie", glibc + apt:  pip wheels, node, rust, go ... behave like on a normal Linux box
#   alpine             Alpine Linux (musl + apk), the small one (what Macoid 3.x used; existing installs keep it)
# Architectures: the phone's own CPU, picked automatically:  arm64 (aarch64), arm (armv7 / 32-bit), x86_64.
#   (there is no "arm128": no such CPU architecture exists.)  Another arch than the phone's needs a qemu-user binary, see lx_qemu.
# Sourced by pkg, lx, shim.sh and brew. Needs $MACOID (set by the app).
. "$MACOID/lib/common.sh"

LX="$MACOID/linux"
LXPROOT="$LX/proot"
LXBINS="$LX/bins"                 # command names that exist inside Linux
LXWRAP="$LX/wrap"                 # one tiny launcher per Linux command; this folder is on PATH, so new commands work at once (like Termux)
LX_BIN_DIRS="usr/local/bin usr/bin bin usr/sbin sbin root/.local/bin root/.cargo/bin root/go/bin"
LX_PROOT_VER=v5.3.0
LX_ALPINE_FALLBACK=3.20.3
LX_DEBIAN_SUITE=trixie

# ---------------------------------------------------------------- which distro, which CPU
lx_distro_get() {
  [ -n "$MACOID_DISTRO" ] && { echo "$MACOID_DISTRO"; return; }
  [ -s "$LX/distro" ] && { cat "$LX/distro"; return; }
  [ -e "$LX/alpine/bin/busybox" ] && { echo alpine; return; }     # installs made by Macoid 3.x keep working
  echo debian
}
LX_DISTRO=$(lx_distro_get)
case "$LX_DISTRO" in alpine|debian) ;; *) echo "macoid: unknown distro '$LX_DISTRO' (use alpine or debian) - using debian" >&2; LX_DISTRO=debian;; esac

lx_host_arch() {   # the phone's CPU: aarch64 | arm | x86_64
  case "$(uname -m 2>/dev/null)" in
    aarch64|arm64) echo aarch64;;
    armv7*|armv8l|arm*) echo arm;;
    x86_64|amd64) echo x86_64;;
    *) return 1;;
  esac
}
lx_norm_arch() {   # any spelling -> aarch64 | arm | x86_64 (empty + status 1 = unknown)
  case "$1" in
    aarch64|arm64|arm64-v8a|armv8) echo aarch64;;
    arm|armv7|armv7l|armhf|arm32|armeabi-v7a) echo arm;;
    x86_64|amd64|x64) echo x86_64;;
    *) return 1;;
  esac
}
LX_HOST=$(lx_host_arch)
_lx_want=${MACOID_LX_ARCH:-$(cat "$LX/arch" 2>/dev/null)}
if [ -n "$_lx_want" ]; then
  LX_GUEST=$(lx_norm_arch "$_lx_want") || { echo "macoid: unknown CPU architecture '$_lx_want' - supported: arm64 (aarch64), arm (armv7), x86_64. Using the phone's own." >&2; LX_GUEST=$LX_HOST; }
else LX_GUEST=$LX_HOST; fi
# the root filesystem lives in a folder per distro (and per arch when it is not the phone's own CPU)
if [ "$LX_GUEST" = "$LX_HOST" ]; then LXROOT="$LX/$LX_DISTRO"; LXTAG=$LX_DISTRO; else LXROOT="$LX/$LX_DISTRO-$LX_GUEST"; LXTAG="$LX_DISTRO-$LX_GUEST"; fi
LXSTAMP="$LX/index.$LXTAG.stamp"
LX_QEMU=""
[ "$LX_GUEST" != "$LX_HOST" ] && LX_QEMU="$LX/qemu/qemu-$LX_GUEST"

lx_alpine_arch() { case "$LX_GUEST" in aarch64) echo aarch64;; arm) echo armv7;; x86_64) echo x86_64;; esac; }
lx_debian_branch() { case "$LX_GUEST" in aarch64) echo dist-arm64v8;; arm) echo dist-arm32v7;; x86_64) echo dist-amd64;; esac; }

lx_ready() {
  [ -x "$LXPROOT" ] || return 1
  [ -f "$LXROOT/.macoid-ready" ] && return 0
  [ "$LX_DISTRO" = alpine ] && [ "$LX_GUEST" = "$LX_HOST" ] && [ -e "$LXROOT/bin/busybox" ]
}

# url dest. The app's downloader retries, resumes a dropped connection from "$2.part" and renames to $2 only when complete.
# A failed download keeps its .part on purpose: the next call continues it instead of starting again.
lx_fetch() {
  /system/bin/sh "$MACOID/bin/wget" -q -O "$2" "$1" && [ -s "$2" ] || { rm -f "$2"; return 1; }
}

# ---------------------------------------------------------------- unpacking the root filesystem
# Android's own tar (toybox) cannot create hard links inside app storage ("can't link"), and a Debian rootfs is full of them:
# the unpack stops half way and libc never arrives. So tar runs inside proot with --link2symlink, which turns every hard
# link into a symlink. Tried in turn: proot default, proot without seccomp, plain tar. Errors go to $LX/untar.err.
lx_rootfs_ok() {     # unpacked completely? (the marker alone is not enough: tar writes it long before libc)
  [ -e "$LXROOT/$_marker" ] || [ -L "$LXROOT/$_marker" ] || return 1
  if [ "$LX_DISTRO" = alpine ]; then ls "$LXROOT"/lib/ld-musl-* >/dev/null 2>&1
  else ls "$LXROOT"/usr/lib/*/libc.so.6 >/dev/null 2>&1; fi
}
lx_untar() {         # lx_untar <rootfs.tar.gz>  -> 0 when $LXROOT is complete; the tarball is removed only then
  _ut_tar=/system/bin/tar; [ -x "$_ut_tar" ] || _ut_tar=tar
  _ut_err="$LX/untar.err"; : > "$_ut_err"
  for _ut_mode in proot noseccomp plain; do
    rm -rf "$LXROOT"; mkdir -p "$LXROOT"
    echo "== unpack mode: $_ut_mode" >> "$_ut_err"
    case "$_ut_mode" in
      proot)      [ -x "$LXPROOT" ] && PROOT_TMP_DIR="$TMPDIR" "$LXPROOT" --link2symlink "$_ut_tar" -xzf "$1" -C "$LXROOT" --exclude='./dev/*' 2>>"$_ut_err";;
      noseccomp)  [ -x "$LXPROOT" ] && PROOT_NO_SECCOMP=1 PROOT_TMP_DIR="$TMPDIR" "$LXPROOT" --link2symlink "$_ut_tar" -xzf "$1" -C "$LXROOT" --exclude='./dev/*' 2>>"$_ut_err";;
      plain)      "$_ut_tar" -xzf "$1" -C "$LXROOT" --exclude='./dev/*' 2>>"$_ut_err";;
    esac
    if lx_rootfs_ok; then rm -f "$1"; return 0; fi
    echo "-> incomplete (mode $_ut_mode)" >> "$_ut_err"
  done
  return 1
}

# ---------------------------------------------------------------- one-time setup
# Downloads the ~1 MB proot engine and the root filesystem (Debian ~30 MB, Alpine ~4 MB), unpacks it, then installs the
# base set (python, pip, git, curl ...). Safe to call again: it returns at once when ready.
lx_setup() {
  lx_ready && return 0
  [ -n "$LX_HOST" ] || { echo "macoid: this CPU ($(uname -m)) is not supported by the Linux engine (supported: arm64, arm, x86_64)" >&2; return 1; }
  mkdir -p "$LX" "$TMPDIR"
  if [ ! -x "$LXPROOT" ]; then
    echo "[macoid] first run: downloading the Linux engine (one time only)..." >&2
    lx_fetch "https://github.com/proot-me/proot/releases/download/$LX_PROOT_VER/proot-$LX_PROOT_VER-$LX_HOST-static" "$LXPROOT" \
      || { echo "macoid: could not download proot (check your internet)" >&2; return 1; }
    chmod 755 "$LXPROOT"
  fi
  if [ -n "$LX_QEMU" ] && [ ! -x "$LX_QEMU" ]; then
    echo "macoid: this phone is $LX_HOST but you asked for $LX_GUEST. That needs a static qemu-user binary at:" >&2
    echo "        $LX_QEMU   (chmod 755). Without it use the phone's own CPU: lx arch default" >&2
    return 1
  fi
  _marker=""
  if [ "$LX_DISTRO" = alpine ]; then _marker="bin/busybox"; else _marker="usr/bin/env"; fi
  if [ ! -e "$LXROOT/$_marker" ]; then
    _tgz="$LX/rootfs.$LXTAG.tar.gz"      # kept until it has unpacked cleanly: a failed unpack never costs a second download
    if [ "$LX_DISTRO" = alpine ]; then
      echo "[macoid] first run: downloading Alpine Linux $(lx_alpine_arch) (one time only)..." >&2
      _aa=$(lx_alpine_arch)
      _base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$_aa"
      _f=$(/system/bin/sh "$MACOID/bin/wget" -q -O - "$_base/latest-releases.yaml" 2>/dev/null \
           | sed -n 's/^ *file: *\(alpine-minirootfs-[^ ]*\.tar\.gz\) *$/\1/p' | head -1)
      [ -n "$_f" ] || { _f="alpine-minirootfs-$LX_ALPINE_FALLBACK-$_aa.tar.gz"; _base="https://dl-cdn.alpinelinux.org/alpine/v${LX_ALPINE_FALLBACK%.*}/releases/$_aa"; }
      _url="$_base/$_f"
    else
      echo "[macoid] first run: downloading Debian ${LX_DEBIAN_SUITE} ($(lx_debian_branch | sed 's/^dist-//')), about 30 MB (one time only)..." >&2
      _url="https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/$(lx_debian_branch)/$LX_DEBIAN_SUITE/slim/oci/blobs/rootfs.tar.gz"
    fi
    # already downloaded (and intact)? then use it. Otherwise download (resumes a half-finished file), check it, and if a
    # resumed file turns out to be damaged (the server file changed meanwhile) throw it away and fetch once more from zero.
    _lx_got=0
    for _lx_try in 1 2; do
      if [ -s "$_tgz" ] && tar -tzf "$_tgz" >/dev/null 2>&1; then _lx_got=1; break; fi
      rm -f "$_tgz"
      [ "$_lx_try" = 2 ] && rm -f "$_tgz.part"
      lx_fetch "$_url" "$_tgz" || { echo "macoid: could not download the Linux root filesystem (check your internet; run again to continue where it stopped)" >&2; return 1; }
    done
    [ "$_lx_got" = 1 ] || { [ -s "$_tgz" ] && tar -tzf "$_tgz" >/dev/null 2>&1 && _lx_got=1; }
    [ "$_lx_got" = 1 ] || { echo "macoid: the downloaded Linux image is damaged; run again to download it fresh" >&2; rm -f "$_tgz" "$_tgz.part"; return 1; }
    if ! lx_untar "$_tgz"; then
      echo "macoid: unpacking the Linux root filesystem failed. The download is kept - run again to retry the unpack." >&2
      tail -n 5 "$LX/untar.err" >&2
      echo "        (still failing? try the small one: lx distro alpine)" >&2
      rm -rf "$LXROOT"; return 1
    fi
  fi
  mkdir -p "$LXROOT/etc" "$LXROOT/root" "$LXROOT/tmp" "$LXROOT/proc" "$LXROOT/sys" "$LXROOT/dev" "$LXROOT/usr/local/bin"
  rm -f "$LXROOT/etc/resolv.conf" "$LXROOT/etc/hosts"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$LXROOT/etc/resolv.conf"
  printf '127.0.0.1 localhost\n::1 localhost\n' > "$LXROOT/etc/hosts"
  if [ "$LX_DISTRO" = debian ]; then
    mkdir -p "$LXROOT/etc/apt/apt.conf.d" "$LXROOT/var/cache/apt/archives/partial"
    # proot has no real users: apt must not drop to its _apt user; no recommends keeps installs small
    printf 'APT::Sandbox::User "root";\nAPT::Install-Recommends "false";\nAcquire::Retries "3";\nDpkg::Use-Pty "0";\n' > "$LXROOT/etc/apt/apt.conf.d/99macoid"
  else mkdir -p "$LXROOT/var/cache/apk"; fi
  lx_write_inner_pkg
  # some phones need seccomp off (or a plainer proot setup); probe the modes in turn and remember the first that works
  if ! lx_probe; then
    echo "macoid: the Linux engine does not start on this phone" >&2
    lx_probe_report >&2
    return 1
  fi
  : > "$LXROOT/.macoid-ready"
  lx_pkg_update >/dev/null 2>&1
  lx_sync_bins
  echo "[macoid] Linux ready ($LX_DISTRO $LX_GUEST, runs on this phone)." >&2
  lx_base
  return 0
}

# the base set: what you expect to be there on a fresh Linux (python, pip, git, curl, ssh). MACOID_LX_BASE=none skips it,
# MACOID_LX_BASE="pkg1 pkg2" replaces it. Retried by 'pkg setup' if the first try had no internet.
lx_base() {
  [ "${MACOID_LX_BASE:-}" = none ] && return 0
  [ -f "$LXROOT/.macoid-base" ] && return 0
  if [ -n "${MACOID_LX_BASE:-}" ]; then _b=$MACOID_LX_BASE
  elif [ "$LX_DISTRO" = debian ]; then _b="python3 python3-pip python3-venv python-is-python3 git curl wget ca-certificates openssh-client"
  else _b="python3 py3-pip git curl wget ca-certificates openssh-client bash"; fi
  echo "[macoid] installing the base set: $_b" >&2
  if lx_pkg_add $_b; then : > "$LXROOT/.macoid-base"; echo "[macoid] base set installed: python, pip, git ready." >&2
  else echo "[macoid] base set not installed (internet?). Run 'pkg setup' to try again." >&2; return 1; fi
}

# 'pkg' inside the Linux shell too (lx), with the same verbs as outside
lx_write_inner_pkg() {
  cat > "$LXROOT/usr/local/bin/pkg" <<'EOS'
#!/bin/sh
# pkg inside Macoid Linux: Termux-style verbs on top of this distro's package manager
sub=$1; [ $# -gt 0 ] && shift
if command -v apt-get >/dev/null 2>&1; then
  case "$sub" in
    install|add|i) exec apt-get install -y --no-install-recommends "$@";;
    remove|uninstall|rm|del|purge) exec apt-get remove -y "$@";;
    search|find) exec apt-cache search "$@";;
    list|ls) exec dpkg-query -W -f '${Package} ${Version}\n';;
    info|show) exec apt-cache show "$@";;
    update|refresh) exec apt-get update;;
    upgrade|full-upgrade) apt-get update && exec apt-get upgrade -y;;
    clean|autoremove) apt-get clean; exec apt-get autoremove -y;;
    *) echo "usage: pkg install|remove|search|list|info|update|upgrade|clean [name...]" >&2; exit 1;;
  esac
else
  case "$sub" in
    install|add|i) exec apk add "$@";;
    remove|uninstall|rm|del|purge) exec apk del "$@";;
    search|find) exec apk search -v "$@";;
    list|ls) exec apk info -v;;
    info|show) exec apk info -a "$@";;
    update|refresh) exec apk update;;
    upgrade|full-upgrade) exec apk upgrade;;
    clean|autoremove) exec apk cache clean;;
    *) echo "usage: pkg install|remove|search|list|info|update|upgrade|clean [name...]" >&2; exit 1;;
  esac
fi
EOS
  chmod 755 "$LXROOT/usr/local/bin/pkg"
}

# ---------------------------------------------------------------- does proot start here?
# Tries: default, seccomp off, seccomp off + plain mode. The first one that runs "true" is kept ($LX/noseccomp, $LX/safe).
# Everything proot says goes to $LX/probe.log so a failure can be shown instead of guessed.
lx_probe() {
  _lxlog="$LX/probe.log"; : > "$_lxlog"
  {
    echo "date: $(date 2>/dev/null)"
    echo "uname: $(uname -a 2>/dev/null)"
    echo "android sdk: $(getprop ro.build.version.sdk 2>/dev/null)  device: $(getprop ro.product.model 2>/dev/null)"
    echo "proot: $(ls -l "$LXPROOT" 2>&1)"
    echo "proot --version: $("$LXPROOT" --version 2>&1 | head -n 2)"
    echo "TMPDIR=$TMPDIR HOME=$HOME"
  } >> "$_lxlog" 2>&1
  for _lxm in default noseccomp safe; do
    rm -f "$LX/noseccomp" "$LX/safe"
    case "$_lxm" in noseccomp) : > "$LX/noseccomp";; safe) : > "$LX/noseccomp"; : > "$LX/safe";; esac
    echo "== mode: $_lxm" >> "$_lxlog"
    _lxrc=0; _lx_proot true >>"$_lxlog" 2>&1 || _lxrc=$?
    [ "$_lxrc" = 0 ] && { echo "-> works" >> "$_lxlog"; return 0; }
    echo "-> failed (exit $_lxrc)" >> "$_lxlog"
  done
  rm -f "$LX/noseccomp" "$LX/safe"
  return 1
}
lx_probe_report() {
  echo "---- proot said (full log: $LX/probe.log) ----"
  tail -n 25 "$LX/probe.log" 2>/dev/null
  echo "---- root filesystem check ----"
  for _f in usr/bin/env usr/bin/true bin/sh; do
    if [ -e "$LXROOT/$_f" ] || [ -L "$LXROOT/$_f" ]; then echo "ok    $_f"; else echo "MISSING $_f"; fi
  done
  if ls "$LXROOT"/usr/lib/*/libc.so.6 "$LXROOT"/lib/ld-musl-* >/dev/null 2>&1; then echo "ok    libc"
  else echo "MISSING libc: the unpack was incomplete. It was wiped; run the command again to download and unpack it fresh."; rm -rf "$LXROOT"; fi
  echo "Send these lines (or $LX/probe.log) to get it fixed."
}

# ---------------------------------------------------------------- running things
# raw proot call: _lx_proot <cmd> [args]   (runs as fake root inside the root filesystem)
_lx_proot() {
  [ -f "$LX/noseccomp" ] && export PROOT_NO_SECCOMP=1
  # same paths inside and outside, so project files behave the same; add the current folder if it is outside $HOME
  _lx_extra=""
  case "$PWD/" in "$HOME"/*) ;; *) [ -d "$PWD" ] && _lx_extra="-b $PWD";; esac
  [ -d /storage ] && _lx_extra="$_lx_extra -b /storage"
  [ -n "$LX_QEMU" ] && _lx_extra="$_lx_extra -q $LX_QEMU"
  _lx_sys="-b /sys"
  if [ -f "$LX/safe" ]; then _lx_sys=""      # plain mode: no /sys bind, no fake kernel version
  elif [ "$LX_DISTRO" = debian ]; then _lx_extra="$_lx_extra -k 6.2.1-Macoid"     # glibc wants a believable kernel version
  fi
  PROOT_TMP_DIR="$TMPDIR" "$LXPROOT" --link2symlink -0 --kill-on-exit -r "$LXROOT" \
    -b /dev -b /proc $_lx_sys -b "$HOME" $_lx_extra \
    -w "$PWD" \
    /usr/bin/env -i HOME=/root USER=root LOGNAME=root SHELL=/bin/sh \
      TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-}" LANG=C.UTF-8 TMPDIR=/tmp \
      PATH=/root/.local/bin:/root/.cargo/bin:/root/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      PIP_BREAK_SYSTEM_PACKAGES=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONUNBUFFERED=1 DEBIAN_FRONTEND=noninteractive \
      MACOID_LINUX=1 \
      "$@"
}

# lx_run <cmd> [args]  - run a command inside Linux (sets up on first use)
lx_run() { lx_setup || return 1; _lx_proot "$@"; }

# lx_shell: an interactive shell (bash when the distro has it)
lx_shell() {
  lx_setup || return 1
  if [ -x "$LXROOT/bin/bash" ] || [ -x "$LXROOT/usr/bin/bash" ]; then
    _lx_proot env 'PS1=\[\e[1;32m\]linux\[\e[0m\]:\w # ' /bin/bash --noprofile --norc -i
  else _lx_proot env 'PS1=linux:${PWD} # ' /bin/sh -l; fi
}

# lx_has <name>: does this command exist inside Linux?
lx_has() {
  for _d in usr/local/bin usr/bin bin usr/sbin sbin root/.local/bin root/.cargo/bin root/go/bin; do
    [ -x "$LXROOT/$_d/$1" ] || [ -L "$LXROOT/$_d/$1" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- which package provides a command
lx_pkgs() { if [ "$LX_DISTRO" = debian ]; then lx_pkgs_debian "$1"; else lx_pkgs_alpine "$1"; fi; }

lx_pkgs_alpine() {
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
    mvn) echo maven;;
    gradle) echo gradle;;
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
    git) echo git;;
    llvm-*) echo llvm;;
    xmllint) echo libxml2-utils;;
    xsltproc) echo libxslt;;
    magick|identify|mogrify) echo imagemagick;;
    awk|patch|telnet|nc|diff|cmp|xxd|column|rev|tac|bc|dc|nl|od|hexdump|which|watch|expand|unexpand|fold|fmt|comm|join|split|csplit|md5sum|sha1sum|sha256sum|sha512sum|cpio|bzip2|bunzip2|xz|unxz|lzma|unzip|zip) echo busybox;;
    *) echo "";;
  esac
}

# last resort: the catalog's command -> package table (lib/cmdpkg.map, one "command package" per line)
lx_pkgs_map() {
  [ -f "$MACOID/lib/cmdpkg.map" ] || return 0
  case "$1" in ''|*[!A-Za-z0-9_+.-]*) return 0;; esac
  __lx_pm=$(printf '%s' "$1" | sed 's/\./\\./g')
  grep "^$__lx_pm " "$MACOID/lib/cmdpkg.map" 2>/dev/null | head -n 1 | cut -d' ' -f2
}

lx_pkgs_debian() {
  case "$1" in
    python|pydoc) echo "python3 python-is-python3";;
    python3|python3.*|pydoc3) echo python3;;
    pip|pip3) echo "python3 python3-pip python-is-python3";;
    pipx) echo pipx;;
    virtualenv) echo "python3-venv virtualenv";;
    uv|uvx) echo uv;;
    node|nodejs|npm|npx|corepack) echo "nodejs npm";;
    yarn) echo yarnpkg;;
    ruby|irb|gem|bundle|bundler|rake|erb|rdoc|ri) echo "ruby bundler";;
    cargo|rustc|rustfmt) echo "cargo rustc";;
    rustup) echo rustup;;
    go|gofmt|golang) echo golang-go;;
    rg) echo ripgrep;;
    nvim) echo neovim;;
    openjdk|jdk|javac|jar) echo default-jdk-headless;;
    java) echo default-jre-headless;;
    gcc|g++|cc|c++|make|ld|ar|as|nm|strip|objdump|ranlib|cpp|gcov) echo build-essential;;
    clang|clang++) echo clang;;
    cmake) echo cmake;;
    mvn) echo maven;;
    gradle) echo gradle;;
    perl) echo perl;;
    php) echo php-cli;;
    lua|lua5.4) echo lua5.4;;
    ssh|scp|sftp|ssh-keygen) echo openssh-client;;
    rsync|tmux|htop|vim|ffmpeg|jq|git|curl|wget|nano|less|tree|bc|file|unzip|zip|patch|xxd|gdb|strace|pkg-config|sqlite3|imagemagick|libxslt) echo "$1";;
    emacs) echo emacs-nox;;
    xmllint) echo libxml2-utils;;
    xsltproc) echo xsltproc;;
    magick|identify|mogrify|convert) echo imagemagick;;
    llvm-*) echo llvm;;
    nc|netcat) echo netcat-openbsd;;
    ps|top|free|watch|uptime|pgrep|pkill) echo procps;;
    dig|nslookup|host) echo bind9-dnsutils;;
    ping) echo iputils-ping;;
    man) echo man-db;;
    *) lx_pkgs_map "$1";;
  esac
}

# lx_ensure <tool>: install the package that provides <tool> if it is missing. 0 = tool usable now
lx_ensure() {
  lx_setup || return 1
  lx_has "$1" && return 0
  __lx_p=$(lx_pkgs "$1")
  [ -n "$__lx_p" ] || return 1
  echo "[macoid] installing $__lx_p ($LX_DISTRO)..." >&2
  lx_pkg_add $__lx_p >&2 || return 1
  lx_has "$1"
}

# ---------------------------------------------------------------- package manager (apk or apt, same interface)
# index: refreshed at most every 12 h and kept on disk, so an install does not re-download it each time
lx_pkg_update() {
  __lx_o="$TMPDIR/pkg-update.$$"
  if [ "$LX_DISTRO" = debian ]; then _lx_proot apt-get update >"$__lx_o" 2>&1; else _lx_proot /sbin/apk update >"$__lx_o" 2>&1; fi
  __lx_rc=$?
  # apt exits 0 even when every mirror failed ("W: Failed to fetch"): that must not count as a fresh index
  if [ $__lx_rc -eq 0 ] && ! grep -q -e 'Failed to fetch' -e 'Could not resolve' -e 'Temporary failure resolving' "$__lx_o" 2>/dev/null; then
    date +%s > "$LXSTAMP"; rm -f "$__lx_o"; return 0
  fi
  cat "$__lx_o" >&2; rm -f "$__lx_o"; return 1
}
lx_index_fresh() {
  [ -s "$LXSTAMP" ] || return 1
  __lx_t=$(cat "$LXSTAMP" 2>/dev/null); __lx_n=$(date +%s)
  case "$__lx_t" in ''|*[!0-9]*) return 1;; esac
  [ "$__lx_n" -ge "$__lx_t" ] && [ $((__lx_n - __lx_t)) -lt 43200 ]
}
_lx_pkg_add_raw() {
  if [ "$LX_DISTRO" = debian ]; then _lx_proot apt-get install -y --no-install-recommends "$@"; else _lx_proot /sbin/apk add "$@"; fi
}
_lx_pkg_missing() {   # does the error text mean "no such package" (not network / engine)?
  grep -q -e 'no such package' -e 'unable to select' -e 'Unable to locate package' -e 'has no installation candidate' -e 'Package .* is not available' "$1" 2>/dev/null
}

# lx_pkg_add <pkg...>: install. Prints progress live and errors afterwards.
#   returns 0 = installed; otherwise 1, and LX_APK_MISSING=1 when the cause is "no such package" (not a network/engine problem)
lx_pkg_add() {
  LX_APK_MISSING=0; __lx_upd=0; __lx_uf=0
  mkdir -p "$TMPDIR"
  if ! lx_index_fresh; then lx_pkg_update && __lx_upd=1 || __lx_uf=1; fi
  __lx_e="$TMPDIR/pkg-add.$$"
  _lx_pkg_add_raw "$@" 2>"$__lx_e"; __lx_rc=$?
  if [ $__lx_rc -ne 0 ] && [ $__lx_upd = 0 ] && { _lx_pkg_missing "$__lx_e" || grep -q -e '404' -e 'Failed to fetch' "$__lx_e" 2>/dev/null; }; then
    if lx_pkg_update; then _lx_pkg_add_raw "$@" 2>"$__lx_e"; __lx_rc=$?; __lx_uf=0; else __lx_uf=1; fi
  fi
  if [ $__lx_rc -ne 0 ]; then
    # "no such package" while the index could not be downloaded just means "no internet": do not call it a missing package
    [ $__lx_uf = 0 ] && _lx_pkg_missing "$__lx_e" && LX_APK_MISSING=1
    cat "$__lx_e" >&2
    [ $__lx_uf = 1 ] && echo "[macoid] the package index could not be downloaded - check your internet connection." >&2
  else
    lx_sync_bins
  fi
  rm -f "$__lx_e"; return $__lx_rc
}
lx_pkg_del() { if [ "$LX_DISTRO" = debian ]; then _lx_proot apt-get remove -y "$@"; else _lx_proot /sbin/apk del "$@"; fi; _r=$?; lx_sync_bins; return $_r; }
lx_pkg_search() { if [ "$LX_DISTRO" = debian ]; then _lx_proot apt-cache search "$@"; else _lx_proot /sbin/apk search -v -- "$@"; fi; }
lx_pkg_list() { if [ "$LX_DISTRO" = debian ]; then _lx_proot dpkg-query -W -f '${Package} ${Version}\n'; else _lx_proot /sbin/apk info -v | sort; fi; }
lx_pkg_info() { if [ "$LX_DISTRO" = debian ]; then _lx_proot apt-cache show "$@"; else _lx_proot /sbin/apk info -a "$@"; fi; }
lx_pkg_upgrade() { if [ "$LX_DISTRO" = debian ]; then lx_pkg_update && _lx_proot apt-get upgrade -y; else _lx_proot /sbin/apk upgrade; fi; _r=$?; lx_sync_bins; return $_r; }
lx_pkg_clean() { if [ "$LX_DISTRO" = debian ]; then _lx_proot apt-get clean; _lx_proot apt-get autoremove -y >/dev/null 2>&1; else _lx_proot /sbin/apk cache clean 2>/dev/null; fi; }
lx_pkg_count() { if [ "$LX_DISTRO" = debian ]; then _lx_proot dpkg-query -f '.\n' -W 2>/dev/null | wc -l; else _lx_proot /sbin/apk info 2>/dev/null | wc -l; fi; }
lx_pkg_installed() {   # name -> 0 if installed
  if [ "$LX_DISTRO" = debian ]; then _lx_proot dpkg -s "$1" >/dev/null 2>&1; else _lx_proot /sbin/apk info -e "$1" >/dev/null 2>&1; fi
}
# old names, kept so third-party skills that call them keep working
lx_apk_add() { lx_pkg_add "$@"; }
lx_apk_update() { lx_pkg_update "$@"; }

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
  case "$1" in pip|pip3|pip3.*|pipx|uv|uvx|npm|pnpm|yarn|gem|bundle|bundler|cargo|go|cpan|luarocks|composer|apt|apt-get|apk|dpkg) lx_sync_bins;; esac
  return 0
}

# lx_use <alpine|debian>: switch distro (each keeps its own files); lx_use_arch <arch|default>
lx_use() {
  case "$1" in alpine|debian) ;; *) echo "usage: lx distro alpine|debian" >&2; return 2;; esac
  mkdir -p "$LX"; echo "$1" > "$LX/distro"
}
lx_use_arch() {
  mkdir -p "$LX"
  if [ "$1" = default ] || [ "$1" = auto ]; then rm -f "$LX/arch"; return 0; fi
  lx_norm_arch "$1" >/dev/null || { echo "unknown architecture '$1' - supported: arm64 (aarch64), arm (armv7), x86_64. There is no arm128." >&2; return 2; }
  echo "$(lx_norm_arch "$1")" > "$LX/arch"
}

# wipes the CURRENT distro/arch root filesystem (others stay)
lx_reset() { rm -rf "$LXROOT" "$LXBINS" "$LXWRAP" "$LXSTAMP"; }
