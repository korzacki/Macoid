# Native engine: prebuilt Termux-style packages that run straight on Android (no proot, no runner, no compiling).
# Sourced by pkg, shim.sh and brew. Needs $MACOID (set by the app); $PREFIX is set by the app too (files/usr).
. "$MACOID/lib/common.sh"
[ -n "$PREFIX" ] || PREFIX="$(dirname "$MACOID")/usr"
NAT_BASE_URL=""; NAT_MODE=termux
[ -f "$MACOID/lib/native.conf" ] && . "$MACOID/lib/native.conf"
[ -f "$HOME/.macoid/native.conf" ] && . "$HOME/.macoid/native.conf"
[ -n "$MACOID_REPO" ] && NAT_BASE_URL=$MACOID_REPO
NAT_BASE_URL=${NAT_BASE_URL%/}
NAT_STAMP="$MACOID/native.stamp"

nat_arch() {
  case "$(uname -m 2>/dev/null)" in
    aarch64|arm64) echo aarch64;;
    armv7*|armv8l|arm*) echo arm;;
    x86_64|amd64) echo x86_64;;
    i?86) echo i686;;
    *) return 1;;
  esac
}
nat_ready() { [ -x "$PREFIX/bin/apt" ] && [ -x "$PREFIX/bin/dpkg" ]; }
# wanted = switched on and either installed already or a repo is configured
nat_wanted() { [ "${MACOID_NATIVE:-1}" != 0 ] && { nat_ready || [ "$NAT_MODE" = termux ] || [ -n "$NAT_BASE_URL" ]; }; }

# nat_run <cmd> [args]: run a command with the native environment (apt/dpkg need the prefix on PATH and termux-exec preloaded)
nat_run() {
  _pre=""
  for _l in "$PREFIX/lib/libtermux-exec-ld-preload.so" "$PREFIX/lib/libtermux-exec.so"; do [ -f "$_l" ] && { _pre=$_l; break; }; done
  if [ -n "$_pre" ]; then
    env PREFIX="$PREFIX" PATH="$PREFIX/bin:$PATH" LD_PRELOAD="$_pre" DEBIAN_FRONTEND=noninteractive "$@"
  else
    env PREFIX="$PREFIX" PATH="$PREFIX/bin:$PATH" DEBIAN_FRONTEND=noninteractive "$@"
  fi
}

# nat_find_bootstrap <arch>: prints "<zip-url> <sha256>" of the newest official Termux bootstrap (apt.android-7 flavour,
# i.e. the one for apps that run from /data/data/... with apt). The sha256 is GitHub's own digest of the release asset.
nat_find_bootstrap() {
  _want="bootstrap-$1.zip"
  _json=$(/system/bin/sh "$MACOID/bin/wget" -q -O - "$NAT_RELEASES_API" 2>/dev/null) || return 1
  printf '%s\n' "$_json" | {
    _tag=""; _hit=0; _sha=""; _kt='"tag_name": "'; _kd='"digest": "sha256:'; _ku='"browser_download_url": "'
    while IFS= read -r _l; do
      case "$_l" in
        *"$_kt"*) _tag=${_l#*"$_kt"}; _tag=${_tag%%\"*}; _hit=0; _sha="";;
        *'"name": "'"$_want"'"'*) case "$_tag" in bootstrap-*apt*android-7*) _hit=1;; esac;;
        *"$_kd"*) [ "$_hit" = 1 ] && { _sha=${_l#*"$_kd"}; _sha=${_sha%%\"*}; };;
        *"$_ku"*"/$_want\""*) if [ "$_hit" = 1 ]; then _u=${_l#*"$_ku"}; _u=${_u%%\"*}; echo "$_u $_sha"; exit 0; fi;;
      esac
    done
    exit 1
  }
}

# One-time setup: download + unpack the bootstrap (one zip), point apt at the repo, refresh the index.
nat_setup() {
  nat_ready && return 0
  _a=$(nat_arch) || { echo "macoid: this CPU ($(uname -m)) has no native bootstrap" >&2; return 1; }
  if [ "$NAT_MODE" = termux ]; then
    if [ -n "$NAT_BOOTSTRAP_URL" ]; then _bu=$NAT_BOOTSTRAP_URL; _sum=$NAT_BOOTSTRAP_SHA256
    else
      echo "[macoid] looking for the newest official Termux bootstrap on GitHub..." >&2
      _r=$(nat_find_bootstrap "$_a") || { echo "macoid: could not find an official bootstrap (no internet, or GitHub is rate-limiting; try again later)" >&2; return 1; }
      _bu=${_r%% *}; _sum=${_r#* }; [ "$_sum" = "$_r" ] && _sum=""
    fi
    echo "[macoid] bootstrap: $_bu" >&2
  else
    [ -n "$NAT_BASE_URL" ] || { echo "macoid: no native repo configured (NAT_BASE_URL in lib/native.conf)" >&2; return 1; }
    _bu="$NAT_BASE_URL/bootstrap-$_a.zip"
    _sum=$(/system/bin/sh "$MACOID/bin/wget" -q -O - "$_bu.sha256" 2>/dev/null | head -1 | cut -d' ' -f1)
  fi
  [ "${#_sum}" -eq 64 ] || { _sum=""; echo "[macoid] warning: no sha256 available for the bootstrap (HTTPS only)" >&2; }
  echo "[macoid] first run: installing the real Termux package system (one time only)..." >&2
  ( jvm bootstrap "$_bu" "$PREFIX" "$_sum" ) || { echo "macoid: bootstrap failed - nothing was changed" >&2; return 1; }
  # newer bootstraps ship a second stage (dpkg configure of the unpacked packages)
  _ss="$PREFIX/etc/termux/termux-bootstrap/second-stage/termux-bootstrap-second-stage.sh"
  if [ -f "$_ss" ]; then
    _sh="$PREFIX/bin/bash"; [ -x "$_sh" ] || _sh="$PREFIX/bin/sh"
    nat_run "$_sh" "$_ss" >&2 || echo "macoid: second stage reported errors (continuing)" >&2
  fi
  if [ "$NAT_MODE" != termux ]; then
    # custom repo only. In termux mode the bootstrap's own signed sources.list + keyring are kept untouched.
    mkdir -p "$PREFIX/etc/apt/sources.list.d"
    rm -f "$PREFIX"/etc/apt/sources.list.d/* 2>/dev/null
    echo "deb [trusted=yes] $NAT_BASE_URL/apt stable main" > "$PREFIX/etc/apt/sources.list"
  fi
  nat_ready || { echo "macoid: bootstrap unpacked but apt/dpkg are missing" >&2; return 1; }
  nat_update >/dev/null
  echo "[macoid] native packages ready." >&2
}

nat_update() {
  nat_run apt update >&2 && date +%s > "$NAT_STAMP"
}
nat_index_fresh() {
  [ -s "$NAT_STAMP" ] || return 1
  _t=$(cat "$NAT_STAMP" 2>/dev/null); _n=$(date +%s)
  case "$_t" in ''|*[!0-9]*) return 1;; esac
  [ "$_n" -ge "$_t" ] && [ $((_n - _t)) -lt 43200 ]
}

# nat_name <name>: Termux package name for a command / Alpine / Debian style name (unknown names pass through)
nat_name() {
  case "$1" in
    python|python3|python3.*|pydoc|pydoc3) echo python;;
    pip|pip3) echo python-pip;;
    node|nodejs|npm|npx|corepack) echo nodejs;;
    go|gofmt|golang) echo golang;;
    cargo|rustc|rustfmt|rust) echo rust;;
    gcc|g++|cc|c++|clang++|build-base|build-essential) echo clang;;
    ssh|scp|sftp|ssh-keygen|openssh-client) echo openssh;;
    rg) echo ripgrep;;
    nvim) echo neovim;;
    java|javac|jar|jdk|openjdk|openjdk17) echo openjdk-21;;
    sqlite3) echo sqlite;;
    xmllint|libxml2-utils) echo libxml2-utils;;
    xsltproc) echo libxslt;;
    magick|identify|mogrify|convert) echo imagemagick;;
    awk) echo gawk;;
    irb|gem|bundle|bundler|rake) echo ruby;;
    emacs|emacs-nox) echo emacs;;
    *) echo "$1";;
  esac
}
# nat_for_tool <command>: package to auto-install when a command is run for the first time (explicit list only,
# so that unknown names never trigger an apt run)
nat_for_tool() {
  case "$1" in
    python|python3|python3.*) echo "python python-pip";;
    pip|pip3|node|nodejs|npm|npx|go|gofmt|cargo|rustc|gcc|g++|cc|c++|clang|clang++|make|cmake|perl|php|ruby|irb|gem|bundle|\
    ssh|scp|sftp|ssh-keygen|rsync|tmux|htop|vim|nvim|emacs|ffmpeg|sqlite3|jq|rg|java|javac|xmllint|xsltproc|magick|awk|nano|yarn|pnpm|lua)
      nat_name "$1";;
    *) echo "";;
  esac
}

# nat_have_pkg <termux-name>: is it in the repo index?
nat_have_pkg() { nat_run apt-cache show "$1" >/dev/null 2>&1; }

# nat_install <name...>: installs what the native repo has. NAT_MISS = the names (as typed) it does not have.
nat_install() {
  NAT_MISS=""
  nat_setup || { NAT_MISS="$*"; return 1; }
  nat_index_fresh || nat_update >/dev/null 2>&1
  _list=""
  for _o in "$@"; do
    case "$_o" in -*) continue;; esac
    _o=${_o%%@*}; _o=${_o%%=*}
    _p=$(nat_name "$_o")
    if nat_have_pkg "$_p"; then _list="$_list $_p"; else NAT_MISS="$NAT_MISS $_o"; fi
  done
  [ -z "$_list" ] && return 0
  nat_run apt install -y $_list >&2
}

# nat_ensure <command>: make a known command available natively. 0 = usable now
nat_ensure() {
  [ -x "$PREFIX/bin/$1" ] && return 0
  _p=$(nat_for_tool "$1"); [ -n "$_p" ] || return 1
  nat_wanted || return 1
  echo "[macoid] installing $_p (native)..." >&2
  nat_install $_p && [ -x "$PREFIX/bin/$1" ]
}

# nat_exec <cmd> [args]: run a command from the native prefix (replaces the shell)
nat_exec() { nat_run "$@"; exit $?; }
