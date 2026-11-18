# Runs a command. Apple-only tools (swift, xcodebuild, xcrun, codesign, simctl ...) go to a GitHub runner (lib/mac.sh);
# everything else runs in the real Linux on the phone (installing the package on first use), then the Apple stand-ins.
# Usage: shim.sh <command> [args]
. "$MACOID/lib/common.sh"
tool=$1; shift
case "$tool" in
  # hardware / OS specific: these inspect or change a Mac, which this phone is not
  kextstat|kmutil|kextload|kextunload|kextcache|csrutil|spctl|tccutil|bputil|fdesetup|firmwarepasswd|nvram|systemsetup|profiles|tmutil|airport|wdutil|powermetrics|sysdiagnose|spindump|purge|dscl|dscacheutil|dsconfigad|dsenableroot|dseditgroup|sysadminctl|pwpolicy|authorizationhost|vsdbutil|reboot|halt|shutdown|dmesg|fsck*|mount_*|newfs_*|asr|bless|hdik|iostat|nettop|sample|leaks|fs_usage)
    echo "$tool: this command inspects or changes the local machine and is not available on Android." >&2; exit 126;;
  # 'su' is only here when the phone has no su binary
  su) echo "su: not found - this phone is not rooted (needs Magisk / KernelSU / APatch)." >&2; exit 127;;
  # not useful inside Macoid
  lldb|passwd|login|ftp)
    echo "$tool: not supported in Macoid." >&2; exit 126;;
esac
# macOS syntax -> Android (lib/mactr.sh): sed -i '', date -v, stat -f, md5, shasum, jot, ditto, mdfind, scutil ...
# status 99 = no rule for this command, carry on below
. "$MACOID/lib/mactr.sh"; mactr_run "$tool" "$@"; _mrc=$?
[ "$_mrc" -ne 99 ] && exit "$_mrc"
# Apple-only tools: a GitHub runner, whatever is installed in the local Linux
case "$tool" in
  swift|swiftc|swift-build|swift-package|swift-test|swift-run|swift-format|swift-demangle|xcodebuild|xcrun|codesign|simctl|ibtool|actool|momc|mapc|iconutil|productbuild|productsign|pkgbuild|notarytool|altool|stapler|xctrace|instruments|xcresulttool|xcstringstool|security)
    . "$MACOID/lib/apple.sh"; apple_dispatch "$tool" "$@"; exit $?;;
esac
if [ "${MACOID_LINUX:-1}" = 0 ]; then
  echo "$tool: command not found (the Linux engine is switched off: MACOID_LINUX=0)" >&2; exit 127
fi
. "$MACOID/lib/linux.sh"
# 1) already inside Linux -> run it there
if lx_ready && lx_has "$tool"; then lx_run "$tool" "$@"; _rc=$?; lx_after "$tool" "$@"; exit $_rc; fi
# 2) a command we know a package for: install on first use (fast, on the phone), then run it
if [ -n "$(lx_pkgs "$tool")" ]; then
  if lx_ensure "$tool"; then lx_run "$tool" "$@"; _rc=$?; lx_after "$tool" "$@"; exit $_rc; fi
  echo "$tool: could not be installed in the local Linux (see the error above). Check your internet, then run it again; 'pkg doctor' shows the state." >&2
  exit 127
fi
# 3) Apple tools that have an on-phone replacement (plutil, lipo, sips ...)
. "$MACOID/lib/apple.sh"
apple_dispatch "$tool" "$@"; _arc=$?
[ $_arc -ne 99 ] && exit $_arc
echo "$tool: command not found." >&2
echo "  Try: pkg search $tool    or    pkg install <package>" >&2
exit 127
