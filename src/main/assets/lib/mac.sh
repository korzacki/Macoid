# Apple runner (4.1): the Apple-only tools - swift, xcodebuild, xcrun, codesign, simctl ... - run on a GitHub Actions runner.
# EVERYTHING ELSE stays on the phone (real Linux, git, gh ...). Sourced by apple.sh / build.sh.
#
#   mac_exec <mac|lnx> <command> [args...]
#     mac = macOS runner (real Xcode), lnx = Ubuntu runner (cheap; only for Swift code that needs no Apple frameworks)
#
# How it works: the current folder is zipped, committed as a throw-away branch "job-..." of a private scratch repo
# (<you>/macoid-cloud), the push starts the workflow, the result (log, exit code, new/changed files) comes back as an
# artifact. The branch and the run are deleted afterwards. Needs: gh auth login (token with repo + workflow scopes).
#
# Settings (environment): MACOID_MAC_REPO owner/repo | MACOID_MAC_RUNNER label (default macos-latest / ubuntu-latest)
#   MACOID_XCODE 16.2 | MACOID_MAC_RETURN changed|all|none | MACOID_MAC_EXCLUDE "dir1 dir2" | MACOID_MAC_ENV "VAR1 VAR2"
#   MACOID_MAC_TIMEOUT minutes (default 60) | MACOID_MAC_KEEP=1 keeps branch/run/job folder for debugging
. "$MACOID/lib/common.sh"

MAC_DIR="$MACOID/mac"
MAC_TPL="$MACOID/lib/apple-job"
MAC_MAXZIP=95000000          # GitHub refuses single files over 100 MB

_mac_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# logged in? which scratch repo?
mac_login() {
  gh auth status >/dev/null 2>&1 || { echo "[macoid] Apple tools run on a GitHub runner, so you must log in first:  gh auth login   (token scopes: repo + workflow)" >&2; return 1; }
  if [ -n "$MACOID_MAC_REPO" ]; then MAC_REPO=$MACOID_MAC_REPO
  else
    MAC_USER=$(cat "$MAC_DIR/user" 2>/dev/null)
    if [ -z "$MAC_USER" ]; then
      MAC_USER=$(gh whoami 2>/dev/null) && [ -n "$MAC_USER" ] || { echo "[macoid] could not read your GitHub login (internet?)" >&2; return 1; }
      mkdir -p "$MAC_DIR"; echo "$MAC_USER" > "$MAC_DIR/user"
    fi
    MAC_REPO="$MAC_USER/macoid-cloud"
  fi
  return 0
}

# the private scratch repo, created once; remembered so later jobs do not even ask GitHub
mac_repo_ensure() {
  [ "$(cat "$MAC_DIR/repo.ok" 2>/dev/null)" = "$MAC_REPO" ] && return 0
  if ! gh repo view "$MAC_REPO" >/dev/null 2>&1; then
    case "$MAC_REPO" in */*) ;; *) echo "[macoid] MACOID_MAC_REPO must look like owner/repo" >&2; return 1;; esac
    echo "[macoid] creating the private repo $MAC_REPO for Apple jobs (once)..." >&2
    gh repo create "${MAC_REPO#*/}" --private -d "Macoid Apple jobs - throw-away branches, safe to delete" >/dev/null \
      || { echo "[macoid] could not create $MAC_REPO (token needs the 'repo' scope)" >&2; return 1; }
  fi
  mkdir -p "$MAC_DIR"; echo "$MAC_REPO" > "$MAC_DIR/repo.ok"
}

# throw away what a job left behind (branch, run, folder); cancel the run when it is still going
mac_cleanup() {
  [ "$MACOID_MAC_KEEP" = 1 ] && { echo "[macoid] kept: branch $MAC_BR in $MAC_REPO, folder $MAC_JOB" >&2; return 0; }
  if [ -n "$MAC_RID" ]; then
    [ "$MAC_DONE" = 1 ] || gh api -X POST "repos/$MAC_REPO/actions/runs/$MAC_RID/cancel" >/dev/null 2>&1
  fi
  [ -n "$MAC_BR" ] && gh api -X DELETE "repos/$MAC_REPO/git/refs/heads/$MAC_BR" >/dev/null 2>&1
  [ -n "$MAC_RID" ] && [ "$MAC_DONE" = 1 ] && gh api -X DELETE "repos/$MAC_REPO/actions/runs/$MAC_RID" >/dev/null 2>&1
  [ -n "$MAC_JOB" ] && rm -rf "$MAC_JOB"
  return 0
}

# one run: build the job commit, push it, wait, bring the result back. Sets MAC_EXIT.
_mac_once() {   # <mac|lnx> <command> [args...]
  _kind=$1; shift
  case "$_kind" in
    lnx) _label=${MACOID_MAC_RUNNER:-ubuntu-latest}; _where="Ubuntu";;
    *)   _kind=mac; _label=${MACOID_MAC_RUNNER:-macos-latest}; _where="macOS";;
  esac
  MAC_ID="$(date +%s)-$$"; MAC_BR="job-$_kind-$MAC_ID"; MAC_JOB="$MAC_DIR/jobs/$MAC_ID"; MAC_RID=""; MAC_DONE=0
  rm -rf "$MAC_JOB"; mkdir -p "$MAC_JOB/macoid" "$MAC_JOB/.github/workflows"
  trap 'echo >&2; echo "[macoid] cancelled" >&2; mac_cleanup; exit 130' INT TERM

  sed -e "s|__RUNNER__|$_label|" -e "s|__TIMEOUT__|${MACOID_MAC_TIMEOUT:-60}|" "$MAC_TPL/apple.yml" > "$MAC_JOB/.github/workflows/apple.yml" \
    || { echo "[macoid] workflow template missing (reinstall the app)" >&2; return 1; }

  # the project: this folder, without git history and the usual heavy build folders
  _xs="-x .git -x .build -x DerivedData -x node_modules -x build-output -x .gradle -x .DS_Store"
  for _e in $MACOID_MAC_EXCLUDE; do _xs="$_xs -x $_e"; done
  # shellcheck disable=SC2086
  zip -q -r "$MAC_JOB/macoid/work.zip" . $_xs >/dev/null 2>&1 || { echo "[macoid] could not pack this folder" >&2; mac_cleanup; return 1; }
  _sz=$(wc -c < "$MAC_JOB/macoid/work.zip" 2>/dev/null | tr -d ' ')
  if [ "${_sz:-0}" -gt "$MAC_MAXZIP" ]; then
    echo "[macoid] this folder packs to $((_sz / 1048576)) MB; GitHub allows ~95 MB. Leave big folders out: MACOID_MAC_EXCLUDE=\"Pods assets\"" >&2
    mac_cleanup; return 1
  fi
  [ -n "$MACOID_XCODE" ] && printf '%s\n' "$MACOID_XCODE" > "$MAC_JOB/macoid/xcode"
  printf '%s\n' "${MACOID_MAC_RETURN:-changed}" > "$MAC_JOB/macoid/return"
  { echo '#!/bin/bash'
    echo 'cd "$GITHUB_WORKSPACE/work" || exit 1'
    for _v in $MACOID_MAC_ENV; do eval "_val=\${$_v}"; printf 'export %s=%s\n' "$_v" "$(_mac_q "$_val")"; done
    printf '%s' "$1"; shift
    for _a in "$@"; do printf ' %s' "$(_mac_q "$_a")"; done
    echo
  } > "$MAC_JOB/macoid/job.sh"

  # push the job as its own branch (the push starts the workflow)
  echo "[macoid] sending to a $_where runner ($MAC_REPO)..." >&2
  _log="$MAC_JOB/git.log"
  ( cd "$MAC_JOB" \
    && git init >/dev/null \
    && git config user.name "Macoid" && git config user.email "macoid@users.noreply.github.com" \
    && git add -A >/dev/null && git commit -m "job $MAC_ID" >/dev/null \
    && git remote add origin "https://github.com/$MAC_REPO.git" \
    && git push origin "refs/heads/main:refs/heads/$MAC_BR" ) > "$_log" 2>&1
  if [ $? -ne 0 ]; then
    cat "$_log" >&2
    grep -qi "workflow" "$_log" && echo "[macoid] GitHub refused the workflow file: the token needs the 'workflow' scope (gh auth login with a new token)." >&2
    mac_cleanup; return 1
  fi

  MAC_RID=$(gh run latest -R "$MAC_REPO" --branch "$MAC_BR" --wait 120) || { echo "[macoid] the push worked but no run started. Is Actions enabled in $MAC_REPO?" >&2; mac_cleanup; return 1; }
  echo "[macoid] run $MAC_RID started" >&2
  _concl=$(gh run wait "$MAC_RID" -R "$MAC_REPO" --timeout "$(( ${MACOID_MAC_TIMEOUT:-60} * 60 + 600 ))")
  if [ -z "$_concl" ]; then echo "[macoid] the runner did not finish in time - run cancelled." >&2; mac_cleanup; return 1; fi
  MAC_DONE=1

  # bring the result back (downloads resume after a dropped connection; nothing is fetched twice)
  _out="$MAC_JOB/out"
  gh run download "$MAC_RID" -R "$MAC_REPO" -n result -D "$_out" >/dev/null || gh run download "$MAC_RID" -R "$MAC_REPO" -n result -D "$_out" >/dev/null
  if [ ! -f "$_out/result/exit" ]; then
    echo "[macoid] the runner did not produce a result. Its log:" >&2
    gh run view "$MAC_RID" -R "$MAC_REPO" --log-failed >&2
    mac_cleanup; return 1
  fi
  MAC_EXIT=$(cat "$_out/result/exit" 2>/dev/null | tr -d ' \n'); [ -n "$MAC_EXIT" ] || MAC_EXIT=1
  MAC_LOG="$_out/result/log.txt"
  MAC_FILES="$_out/result/files"
  trap - INT TERM
  return 0
}

# files the job created or changed come back into the current folder
_mac_restore() {
  [ -d "$MAC_FILES" ] || return 0
  _n=$(find "$MAC_FILES" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "${_n:-0}" -gt 0 ] || return 0
  cp -Rf "$MAC_FILES"/. "$PWD"/ 2>/dev/null || { echo "[macoid] could not copy the result files into $PWD" >&2; return 1; }
  echo "[macoid] $_n file(s) came back:" >&2
  ( cd "$MAC_FILES" && find . -type f | sed 's|^\./||' | head -8 | sed 's|^|    |' >&2 )
  [ "$_n" -gt 8 ] && echo "    ... and $((_n - 8)) more" >&2
  return 0
}

# does this Linux-runner log say "needs a real Mac"? (Apple framework, or no Swift on the image)
_mac_needs_mac() {
  grep -qE "no such module '(SwiftUI|UIKit|AppKit|Combine|CryptoKit|Cocoa|CoreData|CoreGraphics|CoreImage|CoreLocation|CoreML|AVFoundation|AVKit|WebKit|MapKit|SpriteKit|SceneKit|RealityKit|ARKit|StoreKit|WidgetKit|Metal|MetalKit|Vision|GameplayKit|CloudKit|HealthKit|UserNotifications|Photos|PhotosUI|MessageUI|Contacts|EventKit|CoreMotion|CoreBluetooth|Network|OSLog|os|Darwin|ObjectiveC|Security|Accelerate|QuartzCore|CoreText|CoreFoundation)'|swift[a-z-]*: (command )?not found|Apple-only" "$1" 2>/dev/null
}

mac_exec() {   # <mac|lnx> <command> [args...]
  _want=$1; shift
  mac_login || return 1
  mac_repo_ensure || return 1
  mkdir -p "$MAC_DIR/jobs"
  find "$MAC_DIR/jobs" -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} \; 2>/dev/null
  _once_kind=$_want
  while :; do
    _mac_once "$_once_kind" "$@" || return 1
    if [ "$_once_kind" = lnx ] && [ "$MAC_EXIT" != 0 ] && _mac_needs_mac "$MAC_LOG"; then
      echo "[macoid] that needs a real Mac - repeating on a macOS runner..." >&2
      mac_cleanup; _once_kind=mac; continue
    fi
    break
  done
  [ -f "$MAC_LOG" ] && cat "$MAC_LOG"
  _mac_restore
  _rc=$MAC_EXIT
  mac_cleanup
  [ "$_rc" = 0 ] && echo "[macoid] done." >&2 || echo "[macoid] exit code $_rc" >&2
  return "$_rc"
}
