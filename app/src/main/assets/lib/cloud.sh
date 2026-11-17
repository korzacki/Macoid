# Run things on GitHub Actions runners (real macOS / Linux / Windows) from Android.
# Requires: gh auth login (token with repo + workflow scopes)
. "$MACOID/lib/installs.sh"

cloud_snapshot() {   # copy the current dir into $1 without dotfiles/secrets
  _d=$1; mkdir -p "$_d"
  for _f in ./* ./.github ./.gitignore ./.gitattributes ./.editorconfig; do
    [ -e "$_f" ] || continue
    _n=${_f#./}
    case "$_n" in storage|build-output|.macoid-out|'*') continue;; esac
    # keep node_modules (so "npm install" survives between runs) unless it is huge
    [ "$_n" = node_modules ] && [ "$(du -sk "$_f" 2>/dev/null | cut -f1)" -gt 30000 ] && continue
    cp -R "$_f" "$_d/" 2>/dev/null
  done
  find "$_d" \( -name .git -o -name .env -o -name .ssh -o -name .gnupg -o -name github_token -o -name .netrc \) -prune -exec rm -rf {} \; 2>/dev/null
  _kb=$(du -sk "$_d" 2>/dev/null | cut -f1)
  [ "${_kb:-0}" -gt 90000 ] && { echo "macoid: workspace is over 90 MB - run this from a smaller folder" >&2; return 1; }
  return 0
}

# cloud_submit SNAPDIR OUTDIR   (SNAPDIR must contain .github/workflows/macoid.yml)
cloud_submit() {
  _snap=$1; _out=$2
  gh auth status >/dev/null 2>&1 || { echo "macoid: not logged in. Run: gh auth login" >&2; return 1; }
  _login=$(gh api user -q .login) || return 1
  _repo="$_login/macoid-cloud"
  if ! gh repo view "$_repo" >/dev/null 2>&1; then
    echo "[macoid] creating private scratch repo $_repo (used only to run your jobs)" >&2
    gh repo create macoid-cloud --private -d "Macoid cloud runner scratch repo" >/dev/null || return 1
  fi
  _br="job-$(date +%s)"
  ( cd "$_snap" && rm -rf .git && git init -q && git config user.name macoid && git config user.email macoid@users.noreply.github.com \
    && git add -A && git commit -q -m "macoid job $_br" && git remote add origin "https://github.com/$_repo.git" \
    && git push -q --force origin "HEAD:refs/heads/$_br" ) || { echo "macoid: could not push job to $_repo" >&2; return 1; }
  _rid=$(gh run latest -R "$_repo" --branch "$_br" --wait 90) || { echo "macoid: no workflow run started (is Actions enabled for $_repo?)" >&2; return 1; }
  echo "[macoid] run https://github.com/$_repo/actions/runs/$_rid" >&2
  _log="$TMPDIR/cloudlog.$$"
  gh run watch "$_rid" -R "$_repo" > "$_log"; _rc=$?
  if [ -n "$MACOID_BINLOG" ]; then   # commands that an install added on the runner
    sed -n '/MACOID-BEGIN/,/MACOID-END/p' "$_log" | sed -n 's/.*MACOID-NEWBIN: //p' >> "$MACOID_BINLOG"
  fi
  if grep -q 'MACOID-BEGIN' "$_log"; then
    sed -n '/MACOID-BEGIN/,/MACOID-END/p' "$_log" | grep -v 'MACOID-' | sed 's/^[0-9T:.Z-]* //'
  else
    sed 's/^[0-9T:.Z-]* //' "$_log" | tail -n 80
  fi
  rm -f "$_log"
  if [ -n "$_out" ]; then mkdir -p "$_out"; gh run download "$_rid" -R "$_repo" -D "$_out" >/dev/null 2>&1; fi
  gh api -X DELETE "repos/$_repo/git/refs/heads/$_br" >/dev/null 2>&1
  return $_rc
}

# prelude of every cloud job: re-apply saved installs that this command needs
_cloud_pre() {
  cat <<'PRE'
export PIP_BREAK_SYSTEM_PACKAGES=1 PIP_DISABLE_PIP_VERSION_CHECK=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
for __d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/go/bin" "$(npm prefix -g 2>/dev/null)/bin" "$(python3 -m site --user-base 2>/dev/null)/bin" "$(gem env gemdir 2>/dev/null)/bin"; do
  [ -d "$__d" ] && PATH="$__d:$PATH"
done
export PATH
__bins() { for __x in $(printf '%s' "$PATH" | tr ':' ' '); do [ -d "$__x" ] && ls -1 "$__x" 2>/dev/null; done | sort -u; }
if [ "$__rec" = 0 ] && [ -f .macoid/installs.tsv ]; then
  while IFS='|' read -r __e __b __c; do
    [ -n "$__c" ] || continue
    __hit=0
    case " $__eco " in *" $__e "*) __hit=1;; esac
    if [ -n "$__tool" ]; then case " $__b " in *" $__tool "*) __hit=1;; esac; fi
    if [ $__hit = 1 ]; then
      eval "$__c" </dev/null >/dev/null 2>&1 || echo "[macoid] could not re-apply saved install: $__c" >&2
    fi
  done < .macoid/installs.tsv
fi
[ "$__rec" = 1 ] && __bins > "${RUNNER_TEMP:-/tmp}/bins0"
PRE
}
_cloud_post() {
  cat <<'POST'
if [ "$__rec" = 1 ]; then
  __bins > "${RUNNER_TEMP:-/tmp}/bins1"
  printf '%s\n' "MACOID""-NEWBIN: $(comm -13 "${RUNNER_TEMP:-/tmp}/bins0" "${RUNNER_TEMP:-/tmp}/bins1" | tr '\n' ' ')"
fi
exit $__rc
POST
}

# macoid cloud [--os macos|ubuntu|windows] [--fetch] [--sh 'cmd string'] [--] cmd args...
cloud_cmd() {
  _os=macos; _fetch=0; _raw=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --os) _os=$2; shift 2;;
      --fetch) _fetch=1; shift;;
      --sh) _raw=$2; shift 2;;
      --) shift; break;;
      *) break;;
    esac
  done
  _tool=""; _rec=""; _eco=""
  if [ -n "$_raw" ]; then _line=$_raw
  else
    [ $# -gt 0 ] || { echo "usage: macoid cloud [--os macos|ubuntu|windows] [--fetch] [--sh 'cmd'] [--] <command> [args]" >&2; return 2; }
    _tool=$1; _eco=$(tool_eco "$_tool")
    # removing a package only has to forget it: the runner is wiped after every job anyway
    _un=$(uninstall_args "$@")
    if [ -n "$_un" ]; then
      for _p in $_un; do
        if inst_remove "$_p"; then echo "Uninstalled $_p (removed from your saved installs; restart the shell with ^C to drop its command)"
        else echo "$_p: not in your saved installs" >&2; fi
      done
      return 0
    fi
    _rec=$(install_eco "$@")
    _line=""
    for _a in "$@"; do _q=$(printf '%s' "$_a" | sed "s/'/'\\\\''/g"); _line="$_line '$_q'"; done
  fi
  case "$_os" in macos) _runner=macos-latest;; ubuntu|linux) _runner=ubuntu-latest;; windows) _runner=windows-latest;; *) echo "unknown --os $_os" >&2; return 2;; esac
  [ "$_os" = macos ] || { _rec=""; _eco=""; }
  _snap="$TMPDIR/cloud.$$"; rm -rf "$_snap"; mkdir -p "$_snap/.macoid" "$_snap/.github/workflows"
  cloud_snapshot "$_snap" || return 1
  [ -f "$INST_FILE" ] && cp "$INST_FILE" "$_snap/.macoid/installs.tsv"
  _qt=$(printf '%s' "$_tool" | sed "s/'/'\\\\''/g")
  {
    printf "__tool='%s'\n__eco='%s'\n" "$_qt" "$_eco"
    if [ -n "$_rec" ]; then echo "__rec=1"; else echo "__rec=0"; fi
    _cloud_pre
    printf '%s\n' "$_line"
    echo '__rc=$?'
    _cloud_post
  } > "$_snap/.macoid/cmd.sh"
  sed "s/__RUNNER__/$_runner/" "$MACOID/templates/cloud-exec.yml" > "$_snap/.github/workflows/macoid.yml"
  echo "[macoid] running on a GitHub $_runner runner..." >&2
  _out=""; [ "$_fetch" = 1 ] && _out="$TMPDIR/cloudout.$$"
  _bl="$TMPDIR/binlog.$$"; : > "$_bl"
  [ -n "$_rec" ] && MACOID_BINLOG=$_bl || MACOID_BINLOG=""
  cloud_submit "$_snap" "$_out"; _rc=$?
  MACOID_BINLOG=""
  if [ -n "$_out" ] && [ -d "$_out/out" ]; then cp -R "$_out/out/." . 2>/dev/null; fi
  if [ -n "$_rec" ] && [ $_rc -eq 0 ]; then
    _nb=$(tr '\n' ' ' < "$_bl" | tr -s ' ')
    inst_record "$_rec" "${_nb% }" "${_line# }"
    echo "[macoid] saved - this install will be re-applied automatically whenever you use it again (see: macoid installs)" >&2
    [ -n "$_nb" ] && echo "[macoid] new commands: $_nb(restart the shell with ^C to use them)" >&2
  fi
  rm -rf "$_snap" "$_out" "$_bl"
  return $_rc
}

cloud_detect() {
  set -- *.xcworkspace; [ -e "$1" ] && { echo ios; return; }
  set -- *.xcodeproj;   [ -e "$1" ] && { echo ios; return; }
  [ -f Package.swift ] && { echo swift; return; }
  [ -f pubspec.yaml ] && { echo flutter-apk; return; }
  if [ -f package.json ]; then grep -q '"electron"' package.json && { echo electron; return; }; echo node; return; fi
  [ -f pom.xml ] && { echo maven; return; }
  if [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -f settings.gradle ] || [ -f settings.gradle.kts ]; then
    if [ -f app/src/main/AndroidManifest.xml ] || [ -f src/main/AndroidManifest.xml ]; then echo android-apk; else echo gradle-java; fi; return
  fi
  [ -f Cargo.toml ] && { echo rust; return; }
  [ -f go.mod ] && { echo go; return; }
  [ -f CMakeLists.txt ] && { echo cmake; return; }
  [ -f Makefile ] && { echo cmake; return; }
  set -- *.csproj; [ -e "$1" ] && { echo dotnet; return; }
  set -- *.sln;    [ -e "$1" ] && { echo dotnet; return; }
  [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f main.py ] && { echo python; return; }
  echo ""
}

# macoid build [target] [--scheme S] [--entry file]
build_cmd() {
  _target=""; _scheme=""; _entry=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scheme) _scheme=$2; shift 2;;
      --entry) _entry=$2; shift 2;;
      -*) echo "unknown option $1" >&2; return 2;;
      *) _target=$1; shift;;
    esac
  done
  [ -n "$_target" ] || _target=$(cloud_detect)
  if [ -z "$_target" ] || [ ! -f "$MACOID/templates/$_target.yml" ]; then
    echo "usage: macoid build <target> [--scheme S] [--entry file]"
    echo "targets: $(ls "$MACOID/templates" | grep -v cloud-exec | sed 's/\.yml$//' | tr '\n' ' ')"
    [ -z "$_target" ] && echo "(could not auto-detect the project type here)"
    return 2
  fi
  _snap="$TMPDIR/build.$$"; rm -rf "$_snap"; mkdir -p "$_snap/.macoid" "$_snap/.github/workflows"
  cloud_snapshot "$_snap" || return 1
  cp "$MACOID/templates/$_target.yml" "$_snap/.github/workflows/macoid.yml"
  { [ -n "$_scheme" ] && echo "export SCHEME='$_scheme'"; [ -n "$_entry" ] && echo "export ENTRY='$_entry'"; } > "$_snap/.macoid/env"
  echo "[macoid] building target '$_target' on GitHub Actions..." >&2
  cloud_submit "$_snap" "$PWD/build-output"; _rc=$?
  rm -rf "$_snap"
  [ $_rc -eq 0 ] && echo "[macoid] done. Artifacts are in ./build-output" >&2
  return $_rc
}
