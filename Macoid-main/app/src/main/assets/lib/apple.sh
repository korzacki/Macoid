# Apple-only tools, made to run on the phone. Sourced by shim.sh.
#   plutil, PlistBuddy, lipo, otool, install_name_tool, dwarfdump, sips   -> run on the phone (python / LLVM / ImageMagick in the local Linux)
#   swift, swiftc, swift build ...  -> run in the local Linux when a Swift toolchain is installed there (Debian: pkg install swiftlang)
#   xcodebuild, codesign, simctl, ibtool, actool ...  -> need a real Mac: not available (there is no runner fallback any more)
# apple_dispatch returns 99 when it does not handle the tool.
. "$MACOID/lib/linux.sh"

_apple_nomac() {   # tool
  echo "$1: needs a real Mac (Xcode). It cannot run on this phone, and Macoid no longer sends work to GitHub runners." >&2
  return 127
}

# ---------------------------------------------------------------- swift (local Linux only)
_apple_swift() {   # tool args...
  _t=$1; shift
  if lx_ready && lx_has "$_t"; then lx_run "$_t" "$@"; return $?; fi
  if [ "$LX_DISTRO" = debian ] && lx_setup && lx_pkg_add swiftlang >&2 && lx_has "$_t"; then lx_run "$_t" "$@"; return $?; fi
  echo "$_t: no Swift toolchain in the local Linux ($LX_DISTRO $LX_GUEST)." >&2
  echo "  On Debian 13 try: pkg install swiftlang  (arm64 / x86_64). Code that imports SwiftUI, UIKit, AppKit ... cannot build outside a Mac anyway." >&2
  return 127
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

# ---------------------------------------------------------------- xcrun: pass the tool name on (SDK / toolchain selection needs a real Xcode)
_apple_xcrun() {
  for _a in "$@"; do
    case "$_a" in
      --sdk|-sdk|--toolchain|-toolchain|--find|-f|--show-*|-l|--log) _apple_nomac xcrun; return $?;;
    esac
  done
  while [ $# -gt 0 ]; do case "$1" in -v|--verbose|-n|--no-cache|-k|--kill-cache) shift;; *) break;; esac; done
  [ $# -gt 0 ] || { echo "usage: xcrun [-v] <tool> [args...]" >&2; return 1; }
  /system/bin/sh "$MACOID/lib/shim.sh" "$@"
}

apple_dispatch() {   # <tool> [args]
  _at=$1; shift
  case "$_at" in
    swift|swiftc|swift-build|swift-package|swift-test|swift-run|swift-format|swift-demangle) _apple_swift "$_at" "$@"; return $?;;
    xcodebuild|codesign|simctl|ibtool|actool|productbuild|productsign|pkgbuild|notarytool|altool|stapler|xctrace|instruments|iconutil) _apple_nomac "$_at"; return $?;;
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
