# Apple-only tools, made fast. Sourced by shim.sh (and cloud.sh for `macoid build swift`).
#   1. small tools run ON the phone, instantly: plutil, PlistBuddy, lipo, otool, install_name_tool, dwarfdump, sips
#   2. swift / swiftc / swift build ... run on a Linux (ubuntu) runner: it starts in seconds, Swift is preinstalled and it does
#      not use the 10x macOS minutes. A real Mac is used only when the code imports an Apple-only framework (SwiftUI, UIKit ...)
#   3. xcodebuild, codesign, simctl ... have no substitute and still run on a real Mac (xcodebuild gets quicker flags)
# apple_dispatch returns 99 when it does not handle the tool, so the caller falls back to the real Mac.
. "$MACOID/lib/linux.sh"

# frameworks that do not exist in Swift on Linux
APPLE_RE='SwiftUI|SwiftUICore|UIKit|AppKit|Cocoa|WatchKit|WidgetKit|AppIntents|SwiftData|CoreData|CoreGraphics|CoreImage|CoreML|CoreText|CoreAudio|CoreMedia|CoreVideo|CoreServices|MobileCoreServices|UniformTypeIdentifiers|QuartzCore|AVFoundation|AVKit|MapKit|WebKit|StoreKit|Combine|SpriteKit|SceneKit|RealityKit|ARKit|Metal|MetalKit|CloudKit|HealthKit|Photos|PhotosUI|Vision|VisionKit|NaturalLanguage|CoreLocation|CoreMotion|CoreBluetooth|Contacts|EventKit|UserNotifications|LocalAuthentication|Security|CryptoKit|OSLog|os|Darwin|Accelerate|GameKit|GameplayKit|PencilKit|Charts|Network|SystemConfiguration|IOKit|ServiceManagement|AppleArchive|Compression|SafariServices|MessageUI|Intents|TipKit|ActivityKit|PassKit'

_apple_load_cloud() { command -v cloud_cmd >/dev/null 2>&1 || . "$MACOID/lib/cloud.sh"; }
_apple_cloud_ok() {
  [ "${MACOID_CLOUD:-1}" != 0 ] && return 0
  echo "$1: needs a GitHub runner but the cloud is disabled (MACOID_CLOUD=0)" >&2; return 1
}

# ---------------------------------------------------------------- swift
# swift_where [args]: prints "ubuntu" or "macos" (the reason goes to stderr)
swift_where() {
  case "${MACOID_SWIFT:-auto}" in macos|mac) echo macos; return 0;; ubuntu|linux) echo ubuntu; return 0;; esac
  case "$1" in --version|-version|--help|-h|help) echo ubuntu; return 0;; esac
  _l="$TMPDIR/swiftfiles.$$"; : > "$_l"
  for _a in "$@"; do case "$_a" in *.swift) [ -f "$_a" ] && echo "$_a" >> "$_l";; esac; done
  [ -s "$_l" ] || find . -maxdepth 6 -name '*.swift' ! -path './.build/*' ! -path './.git/*' ! -path './.macoid/*' 2>/dev/null | head -400 > "$_l"
  _hit=""
  [ -s "$_l" ] && _hit=$(xargs grep -lE "^(@testable[[:space:]]+)?import[[:space:]]+($APPLE_RE)([[:space:].;]|\$)" < "$_l" 2>/dev/null | head -1)
  rm -f "$_l"
  if [ -n "$_hit" ]; then
    echo "[macoid] swift: $_hit imports an Apple-only framework -> real Mac (slower). MACOID_SWIFT=ubuntu forces the fast Linux runner." >&2
    echo macos
  else
    echo "[macoid] swift: no Apple-only framework found -> fast Linux runner. MACOID_SWIFT=macos forces a real Mac." >&2
    echo ubuntu
  fi
}

_apple_swift() {   # tool args...
  _t=$1; shift
  if [ $# -eq 0 ] && [ "$_t" = swift ]; then echo "swift: the interactive REPL is not supported. Run a file (swift file.swift) or a package (swift run)." >&2; return 126; fi
  _apple_cloud_ok "$_t" || return 1
  _apple_load_cloud
  _w=$(swift_where "$@")
  if [ "$_w" = macos ]; then cloud_cmd --os macos --fetch -- "$_t" "$@"; return $?; fi
  _log="$TMPDIR/swift.$$.log"
  cloud_cmd --os ubuntu --fetch -- "$_t" "$@" > "$_log" 2>&1; _rc=$?
  cat "$_log"
  # code that needs a framework we could not see (e.g. an import hidden in #if): run it again on a real Mac
  if grep -qE "(no such module|unable to find module dependency:) '($APPLE_RE)'" "$_log"; then
    rm -f "$_log"
    echo "[macoid] this code needs an Apple framework -> running again on a real Mac" >&2
    cloud_cmd --os macos --fetch -- "$_t" "$@"; return $?
  fi
  rm -f "$_log"; return $_rc
}

# ---------------------------------------------------------------- plist (plutil, PlistBuddy)
_apple_py() {   # --plutil|--plistbuddy args...
  lx_ensure python3 || { echo "plutil/PlistBuddy need the local Linux (python3). Try: pkg setup" >&2; return 1; }
  _dst="$LXROOT/usr/local/bin/macoid-plist.py"
  cmp -s "$MACOID/lib/plist.py" "$_dst" 2>/dev/null || { mkdir -p "$LXROOT/usr/local/bin"; cp "$MACOID/lib/plist.py" "$_dst"; }
  lx_run python3 /usr/local/bin/macoid-plist.py "$@"
}

# ---------------------------------------------------------------- Mach-O tools (LLVM)
_apple_llvm() {   # llvm-name args...
  _n=$1; shift
  lx_ensure "$_n" || { echo "${_n#llvm-}: could not install the LLVM tools in the local Linux (pkg install llvm)" >&2; return 1; }
  lx_run "$_n" "$@"
}

# ---------------------------------------------------------------- sips (ImageMagick underneath; common options only)
_apple_sips() {
  [ $# -eq 0 ] && { echo "usage: sips [-Z max] [-z h w] [--resampleWidth w] [--resampleHeight h] [-r deg] [-f horizontal|vertical] [-s format fmt] [-g pixelWidth|pixelHeight|format|dpiWidth|dpiHeight] [-o out] file ..." >&2; return 1; }
  lx_ensure magick || { echo "sips: could not install ImageMagick in the local Linux" >&2; return 1; }
  _ops=""; _out=""; _fmt=""; _get=""; _files=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -Z|--resampleHeightWidthMax) _ops="$_ops -resize ${2}x${2}"; shift 2;;
      -z|--resampleHeightWidth) _ops="$_ops -resize ${3}x${2}!"; shift 3;;
      --resampleWidth) _ops="$_ops -resize ${2}x"; shift 2;;
      --resampleHeight) _ops="$_ops -resize x${2}"; shift 2;;
      -r|--rotate) _ops="$_ops -rotate $2"; shift 2;;
      -f|--flip) case "$2" in horizontal) _ops="$_ops -flop";; vertical) _ops="$_ops -flip";; esac; shift 2;;
      -c|--cropToHeightWidth) _ops="$_ops -gravity center -crop ${3}x${2}+0+0 +repage"; shift 3;;
      -s|--setProperty) if [ "$2" = format ]; then _fmt=$3; else echo "sips: setting '$2' is not supported here" >&2; fi; shift 3;;
      -g|--getProperty) _get="$_get $2"; shift 2;;
      -o|--out) _out=$2; shift 2;;
      -*) echo "sips: option $1 is not supported here" >&2; return 1;;
      *) _files="$_files$1
"; shift;;
    esac
  done
  [ -n "$_files" ] || { echo "sips: no input file" >&2; return 1; }
  _rc=0
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    [ -f "$_f" ] || { echo "Error: no file was specified or the file does not exist: $_f" >&2; _rc=1; continue; }
    case "$_f" in /*) _abs=$_f;; *) _abs="$PWD/$_f";; esac
    if [ -n "$_get" ] && [ -z "$_ops$_fmt" ]; then
      echo "$_abs"
      for _k in $_get; do
        case "$_k" in
          pixelWidth)  _v=$(lx_run magick identify -format '%w' "$_f[0]");;
          pixelHeight) _v=$(lx_run magick identify -format '%h' "$_f[0]");;
          format)      _v=$(lx_run magick identify -format '%m' "$_f[0]" | tr 'A-Z' 'a-z');;
          dpiWidth)    _v=$(lx_run magick identify -format '%x' "$_f[0]");;
          dpiHeight)   _v=$(lx_run magick identify -format '%y' "$_f[0]");;
          *) _v="<not supported here>";;
        esac
        echo "  $_k: $_v"
      done
      continue
    fi
    if [ -n "$_out" ]; then
      if [ -d "$_out" ]; then _dst="$_out/${_f##*/}"; else _dst=$_out; fi
    else _dst=$_f; fi
    _tmp="$_dst.sips-tmp.$$"
    if lx_run magick "$_f" $_ops "${_fmt:+$_fmt:}$_tmp"; then mv -f "$_tmp" "$_dst"; echo "$_abs"; [ "$_dst" != "$_f" ] && echo "  $_dst"
    else rm -f "$_tmp"; _rc=1; fi
  done <<EOF2
$_files
EOF2
  return $_rc
}

# ---------------------------------------------------------------- xcrun
_apple_xcrun() {
  for _a in "$@"; do
    case "$_a" in
      --sdk|-sdk|--toolchain|-toolchain|--find|-f|--show-*|-l|--log)   # needs the real Xcode / an Apple SDK
        _apple_cloud_ok xcrun || return 1; _apple_load_cloud
        cloud_cmd --os macos --fetch -- xcrun "$@"; return $?;;
    esac
  done
  while [ $# -gt 0 ]; do case "$1" in -v|--verbose|-n|--no-cache|-k|--kill-cache) shift;; *) break;; esac; done
  [ $# -gt 0 ] || { echo "usage: xcrun [-v] <tool> [args...]" >&2; return 1; }
  /system/bin/sh "$MACOID/lib/shim.sh" "$@"
}

# ---------------------------------------------------------------- xcodebuild (real Mac, quicker flags)
_apple_xcodebuild() {
  _apple_cloud_ok xcodebuild || return 1; _apple_load_cloud
  if [ "${MACOID_XCODEBUILD_RAW:-0}" != 1 ]; then
    _act=0; _q=0; _ci=0
    for _a in "$@"; do
      case "$_a" in
        build|test|archive|build-for-testing|test-without-building) _act=1;;
        -showBuildSettings|-list|-version|-showsdks|-help|-usage|-exportArchive|-showdestinations) _act=0; break;;
        -quiet|-q) _q=1;;
        COMPILER_INDEX_STORE_ENABLE=*) _ci=1;;
      esac
    done
    if [ $_act = 1 ]; then
      [ $_q = 1 ] || set -- "$@" -quiet                                   # a short log is downloaded faster
      [ $_ci = 1 ] || set -- "$@" COMPILER_INDEX_STORE_ENABLE=NO          # skips building the code index (nobody reads it in CI)
    fi
  fi
  cloud_cmd --os macos --fetch -- xcodebuild "$@"
}

apple_dispatch() {   # <tool> [args]
  _at=$1; shift
  case "$_at" in
    swift|swiftc|swift-build|swift-package|swift-test|swift-run|swift-format|swift-demangle) _apple_swift "$_at" "$@"; return $?;;
    xcodebuild) _apple_xcodebuild "$@"; return $?;;
    xcrun) _apple_xcrun "$@"; return $?;;
  esac
  [ "${MACOID_LINUX:-1}" = 0 ] && return 99          # the local tools below need the on-phone Linux
  case "$_at" in
    plutil) _apple_py --plutil "$@";;
    PlistBuddy) _apple_py --plistbuddy "$@";;
    lipo) _apple_llvm llvm-lipo "$@";;
    otool) _apple_llvm llvm-otool "$@";;
    install_name_tool) _apple_llvm llvm-install-name-tool "$@";;
    dwarfdump) _apple_llvm llvm-dwarfdump "$@";;
    sips) _apple_sips "$@";;
    *) return 99;;
  esac
}
