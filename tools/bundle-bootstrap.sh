#!/usr/bin/env bash
# bundle-bootstrap.sh - put the bootstrap zips INTO the APK, the way Termux does (offline first launch).
#
#   tools/bundle-bootstrap.sh <dist-dir | https://base-url>
#       dist-dir  = the ./dist folder that tools/build-repo.sh produced
#       base-url  = where dist/ is published (the same value as NAT_BASE_URL)
#   ARCHES="aarch64 arm x86_64 i686" (default) - architectures that are missing at the source are skipped with a warning.
#
# Result: app/src/main/assets/bootstrap/bootstrap-<arch>.zip. On the first launch the app unpacks the one that matches the
# phone's CPU (NativeBoot.setupIfNeeded). Each zip adds roughly 25-30 MB to the APK, so list only the CPUs you need:
#   ARCHES=aarch64 tools/bundle-bootstrap.sh dist
# Without these files nothing changes: the bootstrap is downloaded on the first "pkg install" (needs NAT_BASE_URL).
set -euo pipefail
SRC="${1:-}"; [ -n "$SRC" ] || { echo "usage: $0 <dist-dir | https://base-url>" >&2; exit 2; }
ARCHES="${ARCHES:-aarch64 arm x86_64 i686}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/app/src/main/assets/bootstrap"
mkdir -p "$DEST"; n=0

fetch() {   # fetch <name> <outfile> -> 0 when got it
  case "$SRC" in
    http://*|https://*) curl -fsSL --retry 3 -o "$2" "${SRC%/}/$1" 2>/dev/null;;
    *) [ -f "$SRC/$1" ] && cp -f "$SRC/$1" "$2";;
  esac
}

for a in $ARCHES; do
  z="bootstrap-$a.zip"; tmp="$DEST/$z.part"
  if ! fetch "$z" "$tmp"; then rm -f "$tmp"; echo "skip $a: $z not found at $SRC"; continue; fi
  if fetch "$z.sha256" "$tmp.sha256"; then
    want=$(head -1 "$tmp.sha256" | cut -d' ' -f1); got=$(sha256sum "$tmp" | cut -d' ' -f1); rm -f "$tmp.sha256"
    [ "$want" = "$got" ] || { rm -f "$tmp"; echo "ERROR: checksum mismatch for $z (want $want, got $got)" >&2; exit 3; }
  else echo "warning: no .sha256 for $z, not verified"; fi
  # a Termux-style bootstrap must contain SYMLINKS.txt, otherwise the app refuses it
  unzip -l "$tmp" 2>/dev/null | grep -q ' SYMLINKS.txt$' || { rm -f "$tmp"; echo "ERROR: $z has no SYMLINKS.txt - not a Termux-style bootstrap" >&2; exit 4; }
  mv -f "$tmp" "$DEST/$z"; echo "bundled $z ($(du -h "$DEST/$z" | cut -f1))"; n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "ERROR: no bootstrap was bundled" >&2; exit 1; }
