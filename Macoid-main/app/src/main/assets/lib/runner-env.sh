# Runs ON the GitHub runner (sourced by .macoid/cmd.sh). Keeps a "runner OS file" per ecosystem:
# a tarball with everything an install added, stored as a release asset (tag macoid-env) in your private
# <you>/macoid-cloud repo. Later jobs just download + extract it instead of installing again.
# Everything here is best-effort: if it fails, the saved install commands are replayed instead.
MACOID_ENV_TAG=macoid-env
__T="${RUNNER_TEMP:-/tmp}"
__sx() { "$@" 2>/dev/null || sudo -n "$@" 2>/dev/null; }

__roots() {   # directories an install of ecosystem $1 writes into
  case "$1" in
    python) python3 -c 'import sys,site;print(sys.prefix);print(site.getusersitepackages());print(site.USER_BASE)' 2>/dev/null;;
    node) npm prefix -g 2>/dev/null;;
    ruby) gem env gemdir 2>/dev/null; echo "$HOME/.gem";;
    rust) echo "$HOME/.cargo/bin";;
    go) echo "$HOME/go/bin";;
    brew) brew --prefix 2>/dev/null;;
  esac | sort -u | while read -r d; do [ -d "$d" ] && echo "$d"; done
}

__env_restore() {   # eco -> 0 if the saved environment was downloaded and extracted
  _a="env-$1.tgz"; _d="$__T/envdl"; rm -rf "$_d"; mkdir -p "$_d"
  command -v gh >/dev/null 2>&1 || return 1
  gh release download "$MACOID_ENV_TAG" -R "$GITHUB_REPOSITORY" -p "$_a" -D "$_d" >/dev/null 2>&1 || return 1
  [ -s "$_d/$_a" ] || return 1
  tar -tzPf "$_d/$_a" > "$__T/prev-$1.list" 2>/dev/null || return 1
  __sx tar -xzPf "$_d/$_a" || return 1
  echo "[macoid] restored saved $1 environment" >&2
  return 0
}

__env_save() {   # eco marker -> pack everything restored + newly added files, upload as release asset
  _e=$1; _m=$2; _a="$__T/env-$_e.tgz"; _l="$__T/save-$_e.list"
  command -v gh >/dev/null 2>&1 || return 1
  { [ -f "$__T/prev-$_e.list" ] && cat "$__T/prev-$_e.list"
    __roots "$_e" | while read -r r; do
      find "$r" \( -type f -o -type l \) -newer "$_m" 2>/dev/null
    done
    printf '%s' "$PATH" | tr ':' '\n' | while read -r r; do
      [ -d "$r" ] && find "$r" -maxdepth 1 \( -type f -o -type l \) -newer "$_m" 2>/dev/null
    done
  } | grep -v -e "^${GITHUB_WORKSPACE:-/nonexistent}/" -e "^$__T/" -e '/Library/Caches/' | sort -u > "$_l"
  [ -s "$_l" ] || return 1
  tar -czPf "$_a" -T "$_l" 2>/dev/null || return 1
  gh release view "$MACOID_ENV_TAG" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1 || \
    gh release create "$MACOID_ENV_TAG" -R "$GITHUB_REPOSITORY" --title "Macoid runner env" --notes "cached runner environments" --target "$GITHUB_SHA" >/dev/null 2>&1 || return 1
  gh release upload "$MACOID_ENV_TAG" "$_a" -R "$GITHUB_REPOSITORY" --clobber >/dev/null 2>&1 || return 1
  echo "[macoid] saved $_e environment ($(du -h "$_a" | cut -f1)) - next runs skip the install" >&2
}

__apply_saved() {   # restore (fast) or replay (slow fallback) the saved installs this command needs
  [ -f .macoid/installs.tsv ] || return 0
  __done=" "
  while IFS='|' read -r __e __b __c; do
    [ -n "$__c" ] || continue
    __hit=0
    case " $__eco " in *" $__e "*) __hit=1;; esac
    if [ -n "$__tool" ]; then case " $__b " in *" $__tool "*) __hit=1;; esac; fi
    [ $__hit = 1 ] || continue
    case "$__done" in *" $__e "*) continue;; esac
    if __env_restore "$__e"; then
      __done="$__done$__e "
    else
      eval "$__c" </dev/null >/dev/null 2>&1 || echo "[macoid] could not re-apply saved install: $__c" >&2
    fi
  done < .macoid/installs.tsv
}
