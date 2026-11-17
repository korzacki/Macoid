# Runs a command: first in the local Linux (fast, on the phone), and only macOS-only tools on a real Mac runner.
# Usage: shim.sh <command> [args]
. "$MACOID/lib/common.sh"
tool=$1; shift
case "$tool" in
  # hardware / OS specific: running these on a cloud VM would report the wrong machine
  kextstat|kmutil|kextload|kextunload|kextcache|csrutil|spctl|tccutil|bputil|fdesetup|firmwarepasswd|nvram|systemsetup|profiles|tmutil|airport|wdutil|powermetrics|sysdiagnose|spindump|purge|dscl|dscacheutil|dsconfigad|dsenableroot|dseditgroup|sysadminctl|pwpolicy|authorizationhost|vsdbutil|reboot|halt|shutdown|dmesg|fsck*|mount_*|newfs_*|asr|bless|hdik|iostat|nettop|sample|leaks|fs_usage)
    echo "$tool: this command inspects or changes the local machine and is not available on Android." >&2; exit 126;;
  # 'su' is only here when the phone has no su binary
  su) echo "su: not found - this phone is not rooted (needs Magisk / KernelSU / APatch)." >&2; exit 127;;
  # need a real terminal
  ssh|telnet|ftp|sftp|lldb|htop|tmux|screen|emacs|passwd|login)
    if [ "${MACOID_LINUX:-1}" != 0 ]; then
      . "$MACOID/lib/linux.sh"
      case "$tool" in ssh|sftp|htop|tmux|emacs|telnet) lx_ensure "$tool" && { lx_run "$tool" "$@"; exit $?; };; esac
    fi
    echo "$tool: interactive terminal programs are not supported in Macoid." >&2; exit 126;;
  python|python3|node|ruby|irb|perl|php|lua|julia|R|ghci|ocaml|iex|erl|sbt|scala|clj|dart|deno|bun)
    # REPLs work when the tool runs locally (below); only the cloud cannot give you a live prompt
    if [ $# -eq 0 ] && { [ "${MACOID_LINUX:-1}" = 0 ] || { . "$MACOID/lib/linux.sh"; ! lx_has "$tool" && [ -z "$(lx_pkgs "$tool")" ]; }; }; then
      echo "$tool: the interactive REPL is not supported. Run a script (e.g. $tool file) or use -c/-e." >&2; exit 126
    fi;;
esac
# Local Linux first: instant (no runner, no upload, no wait). Installs of known tools happen on first use.
if [ "${MACOID_LINUX:-1}" != 0 ] && [ -z "$MACOID_FORCE_CLOUD" ]; then
  . "$MACOID/lib/linux.sh"
  if lx_ready && lx_has "$tool"; then lx_run "$tool" "$@"; exit $?; fi
  if [ -n "$(lx_pkgs "$tool")" ] && lx_ensure "$tool"; then lx_run "$tool" "$@"; exit $?; fi
fi
# what is left needs a real Mac (swift, xcodebuild, codesign, plutil ...)
if [ "${MACOID_CLOUD:-1}" = 0 ]; then echo "$tool: command not found (cloud runner disabled)" >&2; exit 127; fi
. "$MACOID/lib/cloud.sh"
cloud_cmd --os "${MACOID_CLOUD_OS:-macos}" --fetch -- "$tool" "$@"
